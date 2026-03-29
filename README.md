![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![AWS](https://img.shields.io/badge/AWS-Verified-orange)
![GCP](https://img.shields.io/badge/GCP-Verified-green)
![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5-purple)

# AWS to Google Cloud: Workload Identity Federation Guide

## Contents

- [Overview](#why-workload-identity-federation)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Verified Test Results](#verified-test-results)
- [Examples](#examples)
- [Terraform Module](#terraform-module)
- [Enterprise Best Practices](#enterprise-best-practices)
- [Troubleshooting](#troubleshooting)
- [References](#references)

A comprehensive, step-by-step guide to configure **Google Cloud Workload Identity Federation** for AWS workloads — enabling secure, keyless authentication from AWS to Google Cloud services.

## Why Workload Identity Federation?

| Criteria | Service Account Key | Workload Identity Federation |
|----------|--------------------|-----------------------------|
| Secret storage | JSON key file must be secured | No secrets to store |
| Key rotation | Manual, error-prone | Automatic — tokens expire in 1 hour |
| Leak risk | High — keys can leak via git, logs, backups | Nothing to leak |
| Audit trail | Only identifies the Service Account | Traces back to the original AWS identity (ARN) |
| Compliance | Fails many security standards | Aligns with Zero Trust, SOC2, ISO 27001 |

## Architecture

![Architecture Overview](images/wif_architecture.png)

## Authentication Flow

![Authentication Flow](images/wif_auth_flow.png)

1. AWS workload obtains STS token from Instance Metadata Service (EC2), Execution Role (Lambda), or IRSA (EKS).
2. Google Security Token Service receives the AWS token and verifies it by calling back to the AWS STS endpoint.
3. Upon successful verification, Google STS issues a short-lived Federated Token.
4. The Federated Token is used to impersonate a pre-configured Google Cloud Service Account.
5. A Service Account Access Token (1-hour TTL) is issued to call Google Cloud APIs.

## Cost

| Component | Cost |
|-----------|------|
| Workload Identity Pool & Provider | Free |
| Token exchange (STS API) | Free |
| Service Account impersonation | Free |
| Credential configuration file | Free |
| AWS IAM Role & STS calls | Free |

The only costs come from the Google Cloud services you access (BigQuery, Cloud Storage, etc.), which have their own free tiers.

## Supported Use Cases

![Use Cases](images/wif_use_cases.png)

| # | Use Case | AWS Source | GCP Target | Required Role |
|---|----------|-----------|------------|---------------|
| 1 | Data analytics | EC2 | BigQuery | bigquery.dataViewer + bigquery.jobUser |
| 2 | Data sync & backup | EC2 | Cloud Storage | storage.objectAdmin |
| 3 | Cross-cloud inventory | EC2 | Compute Engine | compute.viewer |
| 4 | Infrastructure as Code | EC2 / CodeBuild | Terraform resources | Varies by resource |
| 5 | Centralized logging | EC2 | Cloud Logging | logging.logWriter |
| 6 | Event processing | Lambda | BigQuery / GCS | bigquery.dataEditor |
| 7 | Microservices | EKS Pod | Any GCP service | Varies |
| 8 | CI/CD deployment | CodeBuild | Cloud Run / GKE | run.admin |

---

## Prerequisites

- AWS Account with IAM admin access
- AWS workload with an assigned IAM Role (EC2 Instance Profile, Lambda Execution Role, or EKS IRSA)
- Google Cloud Project with billing enabled
- IAM Admin + Service Account Admin permissions on the GCP project
- gcloud CLI v363.0.0+

---

## Step-by-Step Setup

### Step 1: Gather AWS Identity Information

SSH into your AWS workload and run:

```bash
aws sts get-caller-identity
```

Sample output:

```json
{
    "UserId": "AROAXXXXXXXXXXXXXXXXX:i-0xxxxxxxxxxxxxxxxxx",
    "Account": "XXXXXXXXXXXX",
    "Arn": "arn:aws:sts::XXXXXXXXXXXX:assumed-role/<ROLE_NAME>/i-0xxxxxxxxxxxxxxxxxx"
}
```

Note down: **Account ID**, **Role Name**, and **Full ARN**.

### Step 2: Enable Google Cloud APIs

```bash
gcloud services enable \
  iam.googleapis.com \
  sts.googleapis.com \
  iamcredentials.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  logging.googleapis.com \
  --project=<PROJECT_ID>
```

### Step 3: Create Workload Identity Pool

```bash
gcloud iam workload-identity-pools create <POOL_ID> \
  --project=<PROJECT_ID> \
  --location=global \
  --display-name="AWS Pool"
```

### Step 4: Create AWS Provider

```bash
gcloud iam workload-identity-pools providers create-aws <PROVIDER_ID> \
  --project=<PROJECT_ID> \
  --location=global \
  --workload-identity-pool=<POOL_ID> \
  --account-id=<AWS_ACCOUNT_ID> \
  --attribute-mapping="google.subject=assertion.arn"
```

### Step 5: Create Service Account

```bash
gcloud iam service-accounts create <SA_NAME> \
  --project=<PROJECT_ID> \
  --display-name="AWS Workload SA"
```

### Step 6: Grant Impersonation Permissions

```bash
MEMBER="principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_ID>/subject/<FULL_AWS_ARN>"

# Both roles are required
gcloud iam service-accounts add-iam-policy-binding \
  <SA_NAME>@<PROJECT_ID>.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="${MEMBER}"

gcloud iam service-accounts add-iam-policy-binding \
  <SA_NAME>@<PROJECT_ID>.iam.gserviceaccount.com \
  --role=roles/iam.serviceAccountTokenCreator \
  --member="${MEMBER}"
```

Important notes:
- Use **PROJECT_NUMBER** (numeric), not Project ID
- The **FULL_AWS_ARN** must match exactly, including the instance/resource ID
- Wait 30-60 seconds for IAM policy propagation

### Step 7: Grant GCP Service Permissions

```bash
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --role=<ROLE> \
  --member="serviceAccount:<SA_NAME>@<PROJECT_ID>.iam.gserviceaccount.com"
```

### Step 8: Generate Credential Configuration

```bash
gcloud iam workload-identity-pools create-cred-config \
  projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_ID>/providers/<PROVIDER_ID> \
  --service-account=<SA_NAME>@<PROJECT_ID>.iam.gserviceaccount.com \
  --aws \
  --enable-imdsv2 \
  --output-file=gcp-credentials.json
```

This file contains **no secrets** — safe to store in version control.

### Step 9: Configure AWS Workload

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/gcp-credentials.json
```

---

## Verified Examples

### BigQuery Query

```python
from google.cloud import bigquery

client = bigquery.Client(project="<PROJECT_ID>")

query = """
SELECT corpus, COUNT(*) as word_count
FROM `bigquery-public-data.samples.shakespeare`
GROUP BY corpus ORDER BY word_count DESC LIMIT 5
"""
for row in client.query(query).result():
    print(f"  {row.corpus}: {row.word_count}")
```

Actual output from AWS EC2:

```
Top 5 Shakespeare works by word count:
  hamlet: 5318
  kinghenryv: 5104
  cymbeline: 4875
  troilusandcressida: 4795
  kinglear: 4784
```

### Cloud Storage

```python
from google.cloud import storage

client = storage.Client(project="<PROJECT_ID>")
bucket = client.bucket("<BUCKET_NAME>")

blob = bucket.blob("test/hello.txt")
blob.upload_from_string("Hello from AWS EC2 via Workload Identity Federation!")

content = bucket.blob("test/hello.txt").download_as_text()
print(content)
```

### Cloud Logging

```python
from google.cloud import logging as cloud_logging
import socket, datetime

client = cloud_logging.Client(project="<PROJECT_ID>")
logger = client.logger("aws-application")

logger.log_struct({
    "severity": "INFO",
    "message": "Application started",
    "hostname": socket.gethostname(),
    "source": "aws-ec2"
})
```

Actual output from AWS EC2:

```
Log sent to GCP Cloud Logging successfully!
  Logger: aws-wif-test
  Hostname: ip-172-31-xx-xxx
  Timestamp: 2026-03-29T06:34:55.402882
```

### Lambda Function

```python
import os, json

def lambda_handler(event, context):
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = "/var/task/gcp-credentials.json"
    from google.cloud import bigquery
    client = bigquery.Client(project="<PROJECT_ID>")
    rows = [{"event_source": event.get("source"), "detail": json.dumps(event)}]
    client.insert_rows_json("<PROJECT_ID>.events.lambda_events", rows)
    return {"statusCode": 200}
```

### Terraform from AWS

```hcl
provider "google" {
  project = "<PROJECT_ID>"
  region  = "us-central1"
}

resource "google_bigquery_dataset" "analytics" {
  dataset_id = "cross_cloud_analytics"
  location   = "US"
}

resource "google_storage_bucket" "backups" {
  name     = "<PROJECT_ID>-backups"
  location = "US"
  lifecycle_rule {
    condition { age = 90 }
    action { type = "Delete" }
  }
}
```

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/gcp-credentials.json
terraform init && terraform apply
```

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| Permission iam.serviceAccounts.getAccessToken denied | Missing serviceAccountTokenCreator role | Grant roles/iam.serviceAccountTokenCreator, wait 60s |
| Unable to retrieve AWS region from metadata service | No IAM Role or IMDS disabled | Verify with `aws sts get-caller-identity`; for IMDSv1 remove --enable-imdsv2 |
| The caller does not have permission | SA missing role for target service | Grant the appropriate role per Step 7 |
| Subject mismatch | ARN in binding doesn't match actual ARN | Check actual ARN; note Instance ID changes on replacement |
| Lambda: Could not connect to metadata service | Lambda doesn't use EC2 IMDS | Ensure gcp-credentials.json is bundled in deployment package |

---

## References

- [Workload Identity Federation with AWS](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds)
- [Best Practices for Workload Identity Federation](https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation)
- [Workload Identity Federation with Kubernetes](https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes)
- [AWS IAM Roles for EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html)
- [Terraform Google Cloud Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Verified Test Results

The following end-to-end test was performed on 2026-03-29, authenticating from an AWS EC2 instance to Google Cloud BigQuery via Workload Identity Federation.

### Test Environment

| Component | Detail |
|-----------|--------|
| AWS Identity | EC2 Instance Role (via Instance Metadata Service v2) |
| GCP Project | Lab environment |
| WIF Pool | aws-pool |
| WIF Provider | aws-provider |
| GCP Service Account | aws-bigquery-sa |
| Target Service | BigQuery |

### Test Output

```
$ python3 bigquery_example.py

Connected to BigQuery via AWS Workload Identity Federation!
Test query (Shakespeare word count): 164656

AWS EC2 -> GCP BigQuery: SUCCESS!
```

### Authentication Flow Verified

```
AWS EC2 Instance Metadata (IAM Role credentials)
    |
    v  Token Exchange (SigV4 -> Federated Token)
Google STS
    |
    v  Impersonate
GCP Service Account (access token)
    |
    v  Query
BigQuery (164656 rows counted)
```

---



---

## Enterprise Best Practices

### 1. Pool and Provider Design

Separate pools by environment to prevent cross-environment access:

```
Organization
  +-- Pool: aws-production     (or azure-production)
  |     +-- Provider: account-111111111111
  |     +-- Provider: account-222222222222
  +-- Pool: aws-staging
  |     +-- Provider: account-333333333333
  +-- Pool: aws-development
        +-- Provider: account-444444444444
```

Rules:
- One pool per environment per cloud provider
- One provider per AWS account or Azure tenant
- Never share pools across environments
- Use consistent naming: `{cloud}-{environment}`

### 2. Attribute Mapping and Conditions

Always restrict which identities can authenticate. Never leave attribute conditions empty in production.

**AWS:**
```bash
# Only allow assumed-role ARNs (block IAM users, root)
--attribute-condition="assertion.arn.startsWith('arn:aws:sts::<ACCOUNT_ID>:assumed-role/')"

# Only allow specific roles
--attribute-condition="assertion.arn.contains('assumed-role/production-app/')"

# Map additional attributes for fine-grained access
--attribute-mapping="google.subject=assertion.arn,attribute.aws_role=assertion.arn.extract('assumed-role/{role}/')"
```

**Azure:**
```bash
# Only allow specific managed identities
--attribute-condition="assertion.sub == '<OBJECT_ID>'"

# Only allow specific tenant
--attribute-condition="assertion.tid == '<TENANT_ID>'"
```

### 3. Service Account Strategy

| Pattern | Use Case | Risk Level |
|---------|----------|------------|
| One SA per workload | Production critical apps | Lowest |
| One SA per team | Staging, shared services | Medium |
| One SA per environment | Development only | Highest |

Rules:
- Grant roles at resource level, not project level
- Use custom roles when predefined roles are too broad
- Never use `roles/editor` or `roles/owner` in production
- Review SA permissions quarterly

```bash
# Good: resource-level, specific role
gcloud storage buckets add-iam-policy-binding gs://specific-bucket \
  --role=roles/storage.objectViewer \
  --member="serviceAccount:..."

# Bad: project-level, broad role
gcloud projects add-iam-policy-binding PROJECT \
  --role=roles/editor \
  --member="serviceAccount:..."
```

### 4. Credential Configuration Management

The credential config file contains no secrets, but manage it properly:

| Workload Type | Storage Method |
|---------------|---------------|
| EC2 / Azure VM | File on disk, path in env var |
| Lambda / Functions | Bundled in deployment package |
| EKS / AKS | Kubernetes Secret or ConfigMap |
| CI/CD Pipeline | Pipeline secrets manager |
| Terraform | Environment variable |

Rules:
- Safe to commit to git (no secrets inside)
- Use separate credential configs per SA (one per use case)
- Set `GOOGLE_APPLICATION_CREDENTIALS` env var, never hardcode paths

### 5. Organizational Policy Constraints

Enforce WIF usage across the organization:

```bash
# Disable SA key creation (force WIF)
gcloud org-policies set-policy --project=<PROJECT_ID> << EOF
constraint: iam.disableServiceAccountKeyCreation
booleanPolicy:
  enforced: true
EOF

# Restrict allowed identity providers
gcloud org-policies set-policy --project=<PROJECT_ID> << EOF
constraint: iam.workloadIdentityPoolProviders
listPolicy:
  allowedValues:
    - "aws"
    - "oidc"
EOF

# Disable SA key upload
gcloud org-policies set-policy --project=<PROJECT_ID> << EOF
constraint: iam.disableServiceAccountKeyUpload
booleanPolicy:
  enforced: true
EOF
```

### 6. Monitoring and Audit

Enable and monitor Cloud Audit Logs:

```bash
# Token exchange events (who authenticated)
gcloud logging read '
  resource.type="audited_resource"
  AND protoPayload.serviceName="sts.googleapis.com"
' --project=<PROJECT_ID> --limit=10 --format=json

# SA impersonation events (who got access tokens)
gcloud logging read '
  resource.type="service_account"
  AND protoPayload.methodName="GenerateAccessToken"
' --project=<PROJECT_ID> --limit=10 --format=json
```

Set up alerts:
- Alert on token exchange failures (potential unauthorized access attempts)
- Alert on new principal accessing a SA for the first time
- Alert on access from unexpected AWS accounts or Azure tenants
- Export logs to SIEM via Logpush for centralized monitoring

### 7. Network Security

Use VPC Service Controls to restrict STS access:

```bash
# Create service perimeter
gcloud access-context-manager perimeters create wif-perimeter \
  --resources="projects/<PROJECT_NUMBER>" \
  --restricted-services="sts.googleapis.com,iamcredentials.googleapis.com"
```

Use regional STS endpoints for data residency compliance:
```
https://sts.us-central1.rep.googleapis.com/v1/token
https://sts.europe-west1.rep.googleapis.com/v1/token
https://sts.asia-southeast1.rep.googleapis.com/v1/token
```

### 8. Token Lifetime and Session Management

- Default SA token lifetime: 1 hour (recommended)
- Maximum configurable: 12 hours (requires org policy override)
- Tokens are not revocable - keep lifetime short
- For long-running jobs, implement token refresh in application code

```python
# Python: auto-refresh is built into google-auth library
# Just set GOOGLE_APPLICATION_CREDENTIALS and the library handles refresh
from google.cloud import bigquery
client = bigquery.Client()  # auto-refreshes tokens
```

### 9. Disaster Recovery and High Availability

- Credential config files are stateless - no backup needed
- Pool/Provider config: manage via Terraform with remote state
- If GCP STS is unavailable: workloads cannot authenticate (design for this)
- Mitigation: use regional STS endpoints, implement circuit breaker pattern
- Keep Terraform state in GCS backend with versioning enabled

```hcl
terraform {
  backend "gcs" {
    bucket = "my-terraform-state"
    prefix = "wif"
  }
}
```

### 10. Multi-Cloud Governance

For organizations using both AWS and Azure with GCP:

| Aspect | Recommendation |
|--------|---------------|
| Pool naming | `{cloud}-{environment}` (aws-production, azure-staging) |
| SA naming | `{cloud}-{function}-{environment}` (aws-bigquery-production) |
| Role assignment | Same least-privilege rules regardless of source cloud |
| Monitoring | Unified dashboard for all WIF token exchanges |
| IaC | Separate Terraform modules per cloud, shared variables |
| Rotation | No rotation needed (keyless), but review access quarterly |



---

## Terraform Module

See [terraform/](terraform/) for a production-ready module. Verified with `terraform apply` + BigQuery test on 2026-03-29.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform plan
terraform apply
```

## Examples

| File | Description |
|------|-------------|
| [examples/bigquery_query.py](examples/bigquery_query.py) | Query BigQuery |
| [examples/gcs_sync.py](examples/gcs_sync.py) | Sync files to Cloud Storage |
| [examples/cloud_logging.py](examples/cloud_logging.py) | Send logs to Cloud Logging |

## References

- [GCP: Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds)
- [GCP: WIF Best Practices](https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation)
- [Terraform: Google Cloud Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)

## License

MIT License - see [LICENSE](LICENSE)

