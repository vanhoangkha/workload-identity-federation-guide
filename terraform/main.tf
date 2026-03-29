terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "project_number" {
  description = "GCP Project Number"
  type        = string
}

variable "aws_account_id" {
  description = "AWS Account ID (12 digits)"
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS Account ID must be exactly 12 digits."
  }
}

variable "environment" {
  description = "Environment name (production, staging, development)"
  type        = string
  default     = "production"
}

variable "pool_id" {
  description = "Workload Identity Pool ID"
  type        = string
  default     = "aws-pool"
}

variable "provider_id" {
  description = "Workload Identity Pool Provider ID"
  type        = string
  default     = "aws-provider"
}

variable "service_accounts" {
  description = "Map of service accounts to create with their roles"
  type = map(object({
    display_name    = string
    roles           = list(string)
    aws_role_filter = optional(string, "")
  }))
  default = {
    "bigquery" = {
      display_name    = "AWS BigQuery SA"
      roles           = ["roles/bigquery.dataViewer", "roles/bigquery.jobUser"]
      aws_role_filter = ""
    }
  }
}

# Pool
resource "google_iam_workload_identity_pool" "aws" {
  workload_identity_pool_id = "${var.pool_id}-${var.environment}"
  display_name              = "AWS Pool (${var.environment})"
  description               = "Workload Identity Pool for AWS ${var.environment} workloads"
  project                   = var.project_id
}

# Provider with attribute condition
resource "google_iam_workload_identity_pool_provider" "aws" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.aws.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  project                            = var.project_id

  attribute_mapping = {
    "google.subject"       = "assertion.arn"
    "attribute.account"    = "assertion.account"
    "attribute.aws_role"   = "assertion.arn.extract('assumed-role/{role}/')"
  }

  # Only allow assumed-role ARNs from the specified account
  attribute_condition = "assertion.arn.startsWith('arn:aws:sts::${var.aws_account_id}:assumed-role/')"

  aws {
    account_id = var.aws_account_id
  }
}

# Service Accounts
resource "google_service_account" "workload" {
  for_each     = var.service_accounts
  account_id   = "aws-${each.key}-sa"
  display_name = each.value.display_name
  description  = "SA for AWS workloads - ${each.key} (${var.environment})"
  project      = var.project_id
}

# IAM roles for each SA
resource "google_project_iam_member" "sa_roles" {
  for_each = {
    for pair in flatten([
      for sa_key, sa in var.service_accounts : [
        for role in sa.roles : {
          key  = "${sa_key}-${replace(role, "/", "-")}"
          sa   = sa_key
          role = role
        }
      ]
    ]) : pair.key => pair
  }
  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.workload[each.value.sa].email}"
}

# Workload Identity User binding
resource "google_service_account_iam_member" "wif_user" {
  for_each           = var.service_accounts
  service_account_id = google_service_account.workload[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.aws.name}/*"
}

resource "google_service_account_iam_member" "token_creator" {
  for_each           = var.service_accounts
  service_account_id = google_service_account.workload[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.aws.name}/*"
}

# Outputs
output "pool_id" {
  value = google_iam_workload_identity_pool.aws.workload_identity_pool_id
}

output "provider_id" {
  value = google_iam_workload_identity_pool_provider.aws.workload_identity_pool_provider_id
}

output "service_account_emails" {
  value = { for k, v in google_service_account.workload : k => v.email }
}

output "credential_config_command" {
  value = <<-EOT
    gcloud iam workload-identity-pools create-cred-config \
      ${google_iam_workload_identity_pool_provider.aws.name} \
      --service-account=<SA_EMAIL> \
      --aws --enable-imdsv2 \
      --output-file=gcp-credentials.json
  EOT
}
