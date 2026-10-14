variable "customer_id" {
  description = "Google Workspace customer ID (looks like C0xxxxxxx). Find it in the Admin console under Account settings."
  type        = string
}

variable "primary_domain" {
  description = "Primary Workspace domain. Group addresses on this domain use it."
  type        = string
  default     = "patchworklabs.org"
}

variable "group_members" {
  description = <<-EOT
    Members of each group, as a map of group key to a list of email addresses.
    The group key is a key of local.groups (for example "board").
    Keep real addresses out of git. Pass them in a local tfvars file or in
    TF_VAR_group_members. A group with no entry has no managed members.
  EOT
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.group_members) : contains(keys(local.groups), k)])
    error_message = "Every key of group_members must be a key of local.groups."
  }
}

variable "group_owners" {
  description = "Owners of each group, in the same shape as group_members."
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.group_owners) : contains(keys(local.groups), k)])
    error_message = "Every key of group_owners must be a key of local.groups."
  }
}
