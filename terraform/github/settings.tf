# Live values read from the org on 2026-10-14. Nothing is tightened.
# Two-factor authentication is not required. The provider cannot manage it.
resource "github_organization_settings" "this" {
  billing_email    = "billing@patchworklabs.org"
  name             = "Patchwork Labs"
  description      = "coming soon"
  blog             = "patchworklabs.org"
  twitter_username = "patchworklabsor"

  has_organization_projects = true
  has_repository_projects   = true

  default_repository_permission = "none"

  members_can_create_repositories         = true
  members_can_create_public_repositories  = true
  members_can_create_private_repositories = true
  members_can_create_pages                = true
  members_can_create_public_pages         = true
  members_can_create_private_pages        = true
  members_can_fork_private_repositories   = false

  web_commit_signoff_required = false

  advanced_security_enabled_for_new_repositories               = false
  dependabot_alerts_enabled_for_new_repositories               = true
  dependabot_security_updates_enabled_for_new_repositories     = true
  dependency_graph_enabled_for_new_repositories                = true
  secret_scanning_enabled_for_new_repositories                 = false
  secret_scanning_push_protection_enabled_for_new_repositories = false
}
