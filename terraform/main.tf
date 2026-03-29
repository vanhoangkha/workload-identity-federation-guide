locals {
  pool_id     = "aws-${var.environment}"
  provider_id = "aws-${var.aws_account_id}"

  # Build attribute condition based on allowed roles
  role_conditions = length(var.aws_allowed_roles) > 0 ? join(" || ", [
    for role in var.aws_allowed_roles :
    "assertion.arn.contains('assumed-role/${role}/')"
  ]) : ""

  attribute_condition = length(var.aws_allowed_roles) > 0 ? (
    "assertion.arn.startsWith('arn:aws:sts::${var.aws_account_id}:assumed-role/') && (${local.role_conditions})"
    ) : (
    "assertion.arn.startsWith('arn:aws:sts::${var.aws_account_id}:assumed-role/')"
  )

  # Flatten SA -> role pairs for IAM bindings
  sa_role_pairs = flatten([
    for sa_key, sa in var.service_accounts : [
      for role in sa.roles : {
        key  = "${sa_key}--${replace(role, "roles/", "")}"
        sa   = sa_key
        role = role
      }
    ]
  ])
}

# ─── Workload Identity Pool ───

resource "google_iam_workload_identity_pool" "this" {
  project                   = var.project_id
  workload_identity_pool_id = local.pool_id
  display_name              = "AWS ${title(var.environment)}"
  description               = "WIF pool for AWS workloads (${var.environment})"
  disabled                  = false
}

# ─── AWS Provider ───

resource "google_iam_workload_identity_pool_provider" "this" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.this.workload_identity_pool_id
  workload_identity_pool_provider_id = local.provider_id

  display_name = "AWS Account ${var.aws_account_id}"

  attribute_mapping = {
    "google.subject"     = "assertion.arn"
    "attribute.account"  = "assertion.account"
    "attribute.aws_role" = "assertion.arn.extract('assumed-role/{role}/')"
  }

  attribute_condition = local.attribute_condition

  aws {
    account_id = var.aws_account_id
  }
}

# ─── Service Accounts ───

resource "google_service_account" "this" {
  for_each     = var.service_accounts
  project      = var.project_id
  account_id   = "aws-${each.key}-${var.environment}"
  display_name = "${each.value.display_name} (${var.environment})"
  description  = each.value.description != "" ? each.value.description : "WIF SA for AWS ${each.key} workloads"
}

# ─── IAM: SA -> GCP Resource Roles ───

resource "google_project_iam_member" "sa_roles" {
  for_each = { for pair in local.sa_role_pairs : pair.key => pair }
  project  = var.project_id
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.this[each.value.sa].email}"
}

# ─── IAM: AWS -> SA Impersonation ───

resource "google_service_account_iam_member" "workload_identity_user" {
  for_each           = var.service_accounts
  service_account_id = google_service_account.this[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.this.name}/*"
}

resource "google_service_account_iam_member" "token_creator" {
  for_each           = var.service_accounts
  service_account_id = google_service_account.this[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.this.name}/*"
}

# ─── Enable Required APIs ───

resource "google_project_service" "apis" {
  for_each = toset([
    "iam.googleapis.com",
    "sts.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
