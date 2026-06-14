# Enterprise Hub-and-Spoke Pattern for WIF

## Overview

In multi-account AWS environments, managing WIF providers per spoke account creates sprawl. The **Hub-and-Spoke** pattern consolidates federation through a single dedicated AWS account (the "hub"), reducing the GCP WIF attack surface to one trusted AWS account.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    AWS Spoke Accounts                            │
│                                                                 │
│  Account A (EKS clusters)          Account B (Lambda/EC2)       │
│  ┌─────────────────────────┐      ┌─────────────────────────┐  │
│  │ Pod (IRSA/Pod Identity)  │      │ Lambda / EC2 Instance    │  │
│  │ Role: spoke-role-a       │      │ Role: spoke-role-b       │  │
│  └───────────┬─────────────┘      └───────────┬─────────────┘  │
│              │ sts:AssumeRole                  │ sts:AssumeRole  │
└──────────────┼─────────────────────────────────┼────────────────┘
               ▼                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│              AWS Hub Account (Dedicated)                         │
│              Purpose: WIF federation ONLY - no workloads         │
│                                                                 │
│  ┌─────────────────────┐    ┌─────────────────────┐            │
│  │ Hub Role A           │    │ Hub Role B           │            │
│  │ Trust: spoke-role-a  │    │ Trust: spoke-role-b  │            │
│  └──────────┬──────────┘    └──────────┬──────────┘            │
│             │                          │                        │
│             └──────────┬───────────────┘                        │
│                        │ GetCallerIdentity (SigV4)              │
└────────────────────────┼────────────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│              GCP Workload Identity Federation                    │
│                                                                 │
│  Pool: aws-production                                           │
│  Provider: aws-hub-account (accountId = HUB_ACCOUNT_ID only)    │
│                                                                 │
│  Attribute Mapping:                                             │
│    google.subject = assertion.arn                                │
│    attribute.aws_role = extract role from ARN                    │
│                                                                 │
│  SA Binding: principalSet matched by attribute.aws_role         │
│  → Each hub role maps to exactly one GCP Service Account        │
└────────────────────────┬────────────────────────────────────────┘
                         │ Short-lived access token
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│              GCP Resources                                       │
│  BigQuery, Cloud Storage, Pub/Sub, Cloud Logging, ...           │
└─────────────────────────────────────────────────────────────────┘
```

## Why Hub-and-Spoke?

| Aspect | Direct (1 provider per account) | Hub-and-Spoke |
|--------|--------------------------------|---------------|
| WIF Providers needed | N (one per AWS account) | 1 (hub account only) |
| Blast radius | Each account can federate | Only hub account can federate |
| Audit | Scattered across N accounts | Centralized in hub |
| Scaling | Add provider per new account | Add role in hub (no GCP change) |
| Security controls | Replicated N times | Single point of enforcement |

## Implementation

### Step 1: Create Dedicated Hub Account

The hub account should:
- **Only** contain IAM roles for WIF — no workloads, no compute
- Have MFA enforcement and strict SCPs
- Enable CloudTrail for all AssumeRole events
- Limit admin access to a small operations team

### Step 2: Create Hub Roles

For each workload that needs GCP access, create a role in the hub account:

```bash
# Hub role naming convention: {spoke-account-id}-{environment}-{service-name}
aws iam create-role \
  --role-name "111111111111-prod-invoice-service" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::111111111111:role/eks-prod-invoice-service"
      },
      "Action": "sts:AssumeRole"
    }]
  }'
```

The hub role needs **no permissions** — it only needs to exist so that `GetCallerIdentity` returns its ARN.

### Step 3: Configure GCP WIF Provider (Hub Account Only)

```bash
gcloud iam workload-identity-pools providers create-aws hub-provider \
  --location=global \
  --workload-identity-pool=aws-production \
  --account-id=<HUB_ACCOUNT_ID> \
  --attribute-mapping="google.subject=assertion.arn,attribute.aws_role=assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"
```

> **Key insight:** The attribute mapping strips the session name from the ARN, yielding a stable identifier like `arn:aws:sts::<HUB_ACCOUNT>:assumed-role/<ROLE_NAME>` for principal matching.

### Step 4: Bind GCP Service Account

```bash
PRINCIPAL="principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/aws-production/attribute.aws_role/arn:aws:sts::<HUB_ACCOUNT>:assumed-role/111111111111-prod-invoice-service"

gcloud iam service-accounts add-iam-policy-binding \
  invoice-sa@<PROJECT_ID>.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="$PRINCIPAL"
```

### Step 5: Application Credential Flow

The application (e.g., on EKS) performs:

1. **IRSA injects** spoke role credentials into the pod
2. **Pod assumes** the hub role via `sts:AssumeRole` (cross-account)
3. **google-auth library** uses hub role credentials to sign `GetCallerIdentity`
4. **GCP STS** verifies the signature → issues federated token
5. **Federated token** impersonates GCP SA → short-lived access token

```python
import boto3
from google.auth import aws as google_aws
from google.auth.transport.requests import Request

# Step 1-2: Assume hub role (IRSA creds used automatically by boto3)
sts = boto3.client("sts")
hub_creds = sts.assume_role(
    RoleArn="arn:aws:iam::<HUB_ACCOUNT>:role/111111111111-prod-invoice-service",
    RoleSessionName="wif-session",
)["Credentials"]

# Step 3-5: Exchange for GCP token
import os
os.environ["AWS_ACCESS_KEY_ID"] = hub_creds["AccessKeyId"]
os.environ["AWS_SECRET_ACCESS_KEY"] = hub_creds["SecretAccessKey"]
os.environ["AWS_SESSION_TOKEN"] = hub_creds["SessionToken"]

gcp_creds = google_aws.Credentials.from_info({
    "type": "external_account",
    "audience": "//iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/aws-production/providers/hub-provider",
    "subject_token_type": "urn:ietf:params:aws:token-type:aws4_request",
    "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/invoice-sa@<PROJECT_ID>.iam.gserviceaccount.com:generateAccessToken",
    "token_url": "https://sts.googleapis.com/v1/token",
    "credential_source": {
        "environment_id": "aws1",
        "regional_cred_verification_url": "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15"
    }
}, scopes=["https://www.googleapis.com/auth/cloud-platform"])

gcp_creds.refresh(Request())
# Now use gcp_creds with any Google Cloud client library
```

## Security Controls

### Attribute Conditions (Production Pool)

```bash
# Only allow roles containing 'prod' in their name
--attribute-condition="attribute.aws_role.contains('-prod-')"
```

### Separate Pools per Environment

```
Organization
  +-- Pool: aws-production
  |     +-- Provider: hub-provider (hub account ID)
  |         Condition: attribute.aws_role.contains('-prod-')
  |
  +-- Pool: aws-staging
  |     +-- Provider: hub-provider (same hub account ID)
  |         Condition: attribute.aws_role.contains('-stag-')
  |
  +-- Pool: aws-development
        +-- Provider: hub-provider (same hub account ID)
            Condition: attribute.aws_role.contains('-dev-')
```

### Hub Account SCPs

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyAllExceptSTS",
      "Effect": "Deny",
      "NotAction": [
        "sts:AssumeRole",
        "sts:GetCallerIdentity",
        "iam:*"
      ],
      "Resource": "*"
    }
  ]
}
```

## Onboarding a New Workload

Adding a new workload requires **no changes** to the GCP WIF pool/provider:

1. Create hub role in hub account (Terraform/IaC)
2. Create GCP Service Account
3. Bind SA to the hub role's principal
4. Grant GCP roles to the SA
5. Configure application with hub role ARN

## Terraform Module

See [`terraform/hub-and-spoke/`](../terraform/hub-and-spoke/) for a complete module.

## References

- [GCP: WIF Best Practices](https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation)
- [AWS: Cross-Account Access](https://docs.aws.amazon.com/IAM/latest/UserGuide/tutorial_cross-account-with-roles.html)
- [GCP: Attribute Conditions](https://cloud.google.com/iam/docs/workload-identity-federation#conditions)
