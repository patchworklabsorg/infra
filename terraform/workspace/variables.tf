variable "customer_id" {
  description = "Google Workspace customer ID (looks like C0xxxxxxx). Find it in the Admin console under Account settings."
  type        = string
}

variable "primary_domain" {
  description = "Primary Workspace domain. Group addresses on this domain use it."
  type        = string
  default     = "patchworklabs.org"
}
