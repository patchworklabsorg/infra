terraform {
  required_version = ">= 1.6"

  required_providers {
    googleworkspace = {
      source  = "hashicorp/googleworkspace"
      version = "~> 0.7"
    }
  }

  backend "gcs" {
    bucket = "pwl-tfstate"
    prefix = "workspace"
  }
}

# Credentials are never in files. The provider uses Application Default
# Credentials. Set the impersonated admin and the service account with the
# GOOGLEWORKSPACE_IMPERSONATED_USER_EMAIL and GOOGLEWORKSPACE_SERVICE_ACCOUNT
# environment variables. See README.md.
provider "googleworkspace" {
  customer_id = var.customer_id

  oauth_scopes = [
    "https://www.googleapis.com/auth/admin.directory.orgunit",
    "https://www.googleapis.com/auth/admin.directory.group",
    "https://www.googleapis.com/auth/admin.directory.group.member",
    "https://www.googleapis.com/auth/apps.groups.settings",
  ]
}
