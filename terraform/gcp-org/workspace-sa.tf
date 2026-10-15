# ---------------- Service account for the workspace root ----------------
# Terraform uses this account to manage Google Workspace.
# Do not create keys for it. The org policy blocks keys.
# Admins impersonate it with roles/iam.serviceAccountTokenCreator.
#
# A super admin must add domain-wide delegation by hand in the Admin console:
# Security > Access and data control > API controls > Domain-wide delegation.
# Use the unique ID of this account as the client ID, with these scopes:
#   https://www.googleapis.com/auth/admin.directory.orgunit
#   https://www.googleapis.com/auth/admin.directory.group
#   https://www.googleapis.com/auth/admin.directory.group.member
#   https://www.googleapis.com/auth/apps.groups.settings

resource "google_service_account" "tf_workspace" {
  project      = var.seed_project
  account_id   = "tf-workspace"
  display_name = "Terraform Google Workspace"
  description  = "Terraform impersonates this account to manage Google Workspace. No keys."
}

resource "google_service_account_iam_member" "tf_workspace_impersonate" {
  service_account_id = google_service_account.tf_workspace.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.g.admins
}

output "tf_workspace_service_account_email" {
  description = "Impersonate this account for the workspace root."
  value       = google_service_account.tf_workspace.email
}

output "tf_workspace_service_account_client_id" {
  description = "Client ID for domain-wide delegation in the Admin console."
  value       = google_service_account.tf_workspace.unique_id
}
