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
