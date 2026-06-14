# EKS IRSA to GCP via Workload Identity Federation

## Overview

This guide covers authenticating from **Amazon EKS pods** to **Google Cloud** using:
- **IRSA (IAM Roles for Service Accounts)** for pod-level AWS identity
- **Workload Identity Federation** for keyless GCP access

This is the most secure pattern for Kubernetes workloads — no keys stored anywhere.

## Authentication Flow

```
┌─────────────────────────────────────────────────────────────┐
│  EKS Cluster                                                │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Pod                                                   │  │
│  │  ServiceAccount: my-app                                │  │
│  │  Annotation: eks.amazonaws.com/role-arn                 │  │
│  │                                                        │  │
│  │  Injected by IRSA:                                     │  │
│  │  - AWS_ROLE_ARN                                        │  │
│  │  - AWS_WEB_IDENTITY_TOKEN_FILE (/var/run/secrets/...)  │  │
│  └────────────────────┬──────────────────────────────────┘  │
│                       │                                      │
└───────────────────────┼──────────────────────────────────────┘
                        │ ① boto3 auto-exchanges OIDC token
                        │    for STS temporary credentials
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  AWS STS                                                    │
│  Returns: AccessKeyId, SecretAccessKey, SessionToken        │
│  Identity: arn:aws:sts::<ACCOUNT>:assumed-role/<ROLE>/...   │
└────────────────────────┬────────────────────────────────────┘
                         │ ② (Optional) Assume hub role
                         │    for Hub-and-Spoke pattern
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  google-auth library                                        │
│  Signs GetCallerIdentity request with AWS credentials       │
│  Sends to GCP STS for token exchange                        │
└────────────────────────┬────────────────────────────────────┘
                         │ ③ Token exchange
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  GCP Security Token Service                                 │
│  Verifies SigV4 signature against AWS STS endpoint          │
│  Issues federated token                                     │
└────────────────────────┬────────────────────────────────────┘
                         │ ④ Impersonate SA
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  GCP Service Account                                        │
│  Short-lived access token (1h TTL, auto-refresh)            │
└────────────────────────┬────────────────────────────────────┘
                         │ ⑤ Access GCP resources
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  GCP Resources: BigQuery, GCS, Pub/Sub, etc.                │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- EKS cluster with OIDC provider enabled
- IRSA configured for the pod's ServiceAccount
- GCP WIF pool with AWS provider

## Setup

### 1. EKS IRSA Configuration

```yaml
# Kubernetes ServiceAccount with IRSA annotation
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::<SPOKE_ACCOUNT>:role/eks-prod-my-app"
```

### 2. AWS IAM Role Trust Policy (Spoke)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<SPOKE_ACCOUNT>:oidc-provider/oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:default:my-app",
          "oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

### 3. (Hub-and-Spoke) Spoke Role Permission to Assume Hub Role

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::<HUB_ACCOUNT>:role/<SPOKE_ACCOUNT>-prod-my-app"
    }
  ]
}
```

### 4. GCP WIF Provider

```bash
gcloud iam workload-identity-pools providers create-aws eks-provider \
  --location=global \
  --workload-identity-pool=aws-production \
  --account-id=<HUB_ACCOUNT_ID> \
  --attribute-mapping="google.subject=assertion.arn,attribute.aws_role=assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"
```

### 5. Python Application Code

```python
"""
EKS IRSA → Hub Role → GCP WIF → GCS

IRSA injects AWS_ROLE_ARN + AWS_WEB_IDENTITY_TOKEN_FILE into the pod.
boto3 auto-exchanges those for temporary STS credentials.
We then assume the hub role and use those creds for GCP WIF.
"""
import os
import boto3
from google.auth import aws as google_aws
from google.auth.transport.requests import Request
from google.cloud import storage

HUB_ROLE_ARN = os.environ["HUB_ROLE_ARN"]
WIF_AUDIENCE = os.environ["WIF_AUDIENCE"]
GCP_SA_EMAIL = os.environ["GCP_SA_EMAIL"]
GCP_PROJECT_ID = os.environ["GCP_PROJECT_ID"]
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")


def _assume_hub_role() -> dict:
    """IRSA creds are on the boto3 credential chain automatically."""
    sts = boto3.client("sts", region_name=AWS_REGION)
    return sts.assume_role(
        RoleArn=HUB_ROLE_ARN,
        RoleSessionName="eks-wif-session",
        DurationSeconds=3600,
    )["Credentials"]


def get_gcp_credentials():
    """Exchange hub role credentials for GCP access token."""
    creds = _assume_hub_role()

    os.environ["AWS_ACCESS_KEY_ID"] = creds["AccessKeyId"]
    os.environ["AWS_SECRET_ACCESS_KEY"] = creds["SecretAccessKey"]
    os.environ["AWS_SESSION_TOKEN"] = creds["SessionToken"]
    os.environ["AWS_REGION"] = AWS_REGION
    os.environ["AWS_DEFAULT_REGION"] = AWS_REGION

    gcp_creds = google_aws.Credentials.from_info({
        "type": "external_account",
        "audience": WIF_AUDIENCE,
        "subject_token_type": "urn:ietf:params:aws:token-type:aws4_request",
        "service_account_impersonation_url": (
            f"https://iamcredentials.googleapis.com/v1/projects/-/"
            f"serviceAccounts/{GCP_SA_EMAIL}:generateAccessToken"
        ),
        "token_url": "https://sts.googleapis.com/v1/token",
        "credential_source": {
            "environment_id": "aws1",
            "regional_cred_verification_url": (
                "https://sts.{region}.amazonaws.com"
                "?Action=GetCallerIdentity&Version=2011-06-15"
            ),
        },
    }, scopes=["https://www.googleapis.com/auth/cloud-platform"])

    gcp_creds.refresh(Request())
    return gcp_creds


# Usage
if __name__ == "__main__":
    creds = get_gcp_credentials()
    client = storage.Client(credentials=creds, project=GCP_PROJECT_ID)
    blobs = list(client.list_blobs(os.environ["GCS_BUCKET"], max_results=5))
    for b in blobs:
        print(f"  {b.name}")
```

### 6. Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    metadata:
      labels:
        app: my-app
    spec:
      serviceAccountName: my-app  # IRSA-enabled SA
      containers:
        - name: app
          image: my-app:latest
          env:
            - name: HUB_ROLE_ARN
              value: "arn:aws:iam::<HUB_ACCOUNT>:role/<SPOKE_ACCOUNT>-prod-my-app"
            - name: WIF_AUDIENCE
              value: "//iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/aws-production/providers/hub-provider"
            - name: GCP_SA_EMAIL
              value: "my-app-sa@<GCP_PROJECT>.iam.gserviceaccount.com"
            - name: GCP_PROJECT_ID
              value: "<GCP_PROJECT>"
            - name: GCS_BUCKET
              value: "my-bucket"
```

## Direct Pattern (Without Hub-and-Spoke)

If using a single AWS account, skip the hub role assume step:

```bash
# Register the spoke account directly as WIF provider
gcloud iam workload-identity-pools providers create-aws eks-provider \
  --location=global \
  --workload-identity-pool=aws-production \
  --account-id=<SPOKE_ACCOUNT_ID> \
  --attribute-mapping="google.subject=assertion.arn"
```

The pod uses IRSA credentials directly for WIF token exchange — no intermediate assume role needed.

## IMDSv2 Considerations

EKS nodes typically have IMDSv2 enforced (`HttpTokens=required`). The `google-auth` library (v2.18+) handles IMDSv2 automatically. However, when using IRSA:

- **IRSA bypasses IMDS entirely** — it injects credentials via projected service account tokens
- The `credential_source` in your config won't actually hit IMDS when `AWS_ACCESS_KEY_ID` env vars are set
- This means IMDSv2 enforcement does **not** affect the IRSA → WIF flow

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `An error occurred (AccessDenied) when calling AssumeRole` | Spoke role can't assume hub role | Check hub role trust policy |
| `Could not load credentials from any providers` | IRSA not injecting tokens | Verify SA annotation and OIDC provider |
| `Token exchange failed` | Hub account not registered in WIF provider | Verify `--account-id` matches hub account |
| `principalSet does not match` | Attribute mapping strips session name incorrectly | Check `GetCallerIdentity` output matches mapping |

## References

- [AWS: IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [AWS: EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [GCP: WIF with Kubernetes](https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes)
- [google-auth Python Library](https://google-auth.readthedocs.io/)
