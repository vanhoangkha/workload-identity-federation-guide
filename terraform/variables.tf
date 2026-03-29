variable "project_id" {
  description = "GCP Project ID"
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
  description = "Environment (production, staging, development)"
  type        = string
  default     = "production"
  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "Environment must be production, staging, or development."
  }
}

variable "aws_allowed_roles" {
  description = "List of AWS IAM role names allowed to authenticate. Empty = all roles in the account."
  type        = list(string)
  default     = []
}

variable "service_accounts" {
  description = "Map of service accounts to create"
  type = map(object({
    display_name = string
    description  = optional(string, "")
    roles        = list(string)
  }))
}

variable "enable_audit_logging" {
  description = "Enable Cloud Audit Logs for WIF token exchanges"
  type        = bool
  default     = true
}
