# Terraform: AWS to GCP Workload Identity Federation

Production-ready Terraform module that creates all GCP resources needed for AWS workloads to authenticate via Workload Identity Federation.

## What it creates

- Workload Identity Pool (per environment)
- AWS Provider with attribute mapping and conditions
- Service Accounts with least-privilege roles
- IAM bindings (workloadIdentityUser + serviceAccountTokenCreator)
- Required GCP APIs auto-enabled

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars
terraform init
terraform plan
terraform apply
```

After apply, generate credential config:
```bash
# The command is in terraform output
terraform output -json credential_config_commands
```

## Inputs

| Name | Description | Type | Required | Default |
|------|-------------|------|----------|---------|
| project_id | GCP Project ID | string | yes | - |
| aws_account_id | AWS Account ID (12 digits) | string | yes | - |
| environment | Environment name | string | no | production |
| aws_allowed_roles | AWS IAM roles allowed to authenticate | list(string) | no | [] (all) |
| service_accounts | Map of SAs with roles | map(object) | yes | - |
| enable_audit_logging | Enable audit logs | bool | no | true |

## Outputs

| Name | Description |
|------|-------------|
| pool_name | Full resource name of the WIF Pool |
| provider_name | Full resource name of the WIF Provider |
| service_account_emails | Map of SA key -> email |
| credential_config_commands | gcloud commands to generate credential configs |

## Multi-environment deployment

```bash
# Production
terraform workspace new production
terraform apply -var-file=production.tfvars

# Staging
terraform workspace new staging
terraform apply -var-file=staging.tfvars
```

## Security features

- Attribute condition restricts to assumed-role ARNs only (blocks IAM users)
- Optional role-level filtering via `aws_allowed_roles`
- Per-environment pool isolation
- Least-privilege SA roles
- Auto-enables only required APIs
