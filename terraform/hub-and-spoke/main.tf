# Hub-and-Spoke WIF — Terraform Module

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "project_number" {
  description = "GCP project number"
  type        = string
}

variable "hub_account_id" {
  description = "AWS hub account ID (the only account registered in WIF)"
  type        = string
}

variable "pool_id" {
  description = "Workload Identity Pool ID"
  type        = string
  default     = "aws-production"
}

variable "provider_id" {
  description = "WIF Provider ID"
  type        = string
  default     = "hub-provider"
}

variable "workloads" {
  description = "Map of workloads to onboard"
  type = map(object({
    hub_role_name       = string
    gcp_sa_id           = string
    gcp_sa_display_name = string
    gcp_roles           = list(string)
  }))
}

# --- Pool & Provider (one-time setup) ---

resource "google_iam_workload_identity_pool" "pool" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "AWS Production Pool"
}

resource "google_iam_workload_identity_pool_provider" "aws" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.pool.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "AWS Hub Account"

  aws {
    account_id = var.hub_account_id
  }

  attribute_mapping = {
    "google.subject"     = "assertion.arn"
    "attribute.aws_role" = "assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"
  }
}

# --- Per-workload SA + binding ---

resource "google_service_account" "workload" {
  for_each     = var.workloads
  project      = var.project_id
  account_id   = each.value.gcp_sa_id
  display_name = each.value.gcp_sa_display_name
}

resource "google_service_account_iam_member" "wif_binding" {
  for_each           = var.workloads
  service_account_id = google_service_account.workload[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.pool_id}/attribute.aws_role/arn:aws:sts::${var.hub_account_id}:assumed-role/${each.value.hub_role_name}"
}

resource "google_service_account_iam_member" "token_creator" {
  for_each           = var.workloads
  service_account_id = google_service_account.workload[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.pool_id}/attribute.aws_role/arn:aws:sts::${var.hub_account_id}:assumed-role/${each.value.hub_role_name}"
}

resource "google_project_iam_member" "workload_roles" {
  for_each = { for pair in flatten([
    for wk, wv in var.workloads : [
      for role in wv.gcp_roles : { key = "${wk}-${role}", workload = wk, role = role }
    ]
  ]) : pair.key => pair }

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.workload[each.value.workload].email}"
}

output "pool_name" {
  value = google_iam_workload_identity_pool.pool.name
}

output "provider_name" {
  value = google_iam_workload_identity_pool_provider.aws.name
}

output "service_accounts" {
  value = { for k, v in google_service_account.workload : k => v.email }
}
