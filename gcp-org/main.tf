terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  backend "gcs" {
    bucket = "pwl-tfstate" # create this in the seed project first
    prefix = "gcp-org"
  }
}

variable "org_id" { type = string }
variable "billing_account" { type = string }
variable "seed_project" { type = string } # quota project for org-level APIs
variable "domain" {
  type    = string
  default = "patchworklabs.org"
}

provider "google" {
  user_project_override = true
  billing_project       = var.seed_project
}

locals {
  org = "organizations/${var.org_id}"

  g = {
    admins     = "group:gcp-admins@${var.domain}"
    board      = "group:board@${var.domain}"
    treasurer  = "group:treasurer@${var.domain}"
    infra      = "group:infra@${var.domain}"
    ganymede   = "group:ganymede-admins@${var.domain}"
    hackboston = "group:organizers@hackboston.dev"
    hackhelp   = "group:organizers@hackathon.help"
  }
}

# ---------------- Folders ----------------

resource "google_folder" "common" {
  display_name = "Common"
  parent       = local.org
}

resource "google_folder" "programs" {
  display_name = "Programs"
  parent       = local.org
}

resource "google_folder" "sponsored" {
  display_name = "Sponsored Projects"
  parent       = local.org
}

resource "google_folder" "operations" {
  display_name = "Operations"
  parent       = local.org
}


resource "google_folder" "ganymede" {
  display_name = "Ganymede"
  parent       = google_folder.programs.name
}

resource "google_folder" "ganymede_prod" {
  display_name = "Production"
  parent       = google_folder.ganymede.name
}

resource "google_folder" "ganymede_sandbox" {
  display_name = "Sandbox"
  parent       = google_folder.ganymede.name
}


resource "google_folder" "hackboston" {
  display_name = "HackBoston"
  parent       = google_folder.sponsored.name
}

resource "google_folder" "hackathon_help" {
  display_name = "hackathon-help" # periods aren't allowed in folder names
  parent       = google_folder.sponsored.name
}


resource "google_folder" "infrastructure" {
  display_name = "Infrastructure"
  parent       = google_folder.operations.name
}


# ---------------- Org-level IAM ----------------

locals {
  org_bindings = {
    "admins-orgviewer"    = { member = local.g.admins, role = "roles/resourcemanager.organizationViewer" }
    "admins-folderviewer" = { member = local.g.admins, role = "roles/resourcemanager.folderViewer" }
    "admins-secreviewer"  = { member = local.g.admins, role = "roles/iam.securityReviewer" }
    "board-browser"       = { member = local.g.board, role = "roles/browser" }
  }
}

resource "google_organization_iam_member" "org" {
  for_each = local.org_bindings
  org_id   = var.org_id
  member   = each.value.member
  role     = each.value.role
}

resource "google_billing_account_iam_member" "treasurer" {
  billing_account_id = var.billing_account
  member             = local.g.treasurer
  role               = "roles/billing.viewer"
}

# ---------------- Folder IAM ----------------
# Editor is broad. Tighten per folder once real workloads exist.

locals {
  folder_bindings = {
    "ganymede-editor"   = { folder = google_folder.ganymede.name, member = local.g.ganymede, role = "roles/editor" }
    "hackboston-editor" = { folder = google_folder.hackboston.name, member = local.g.hackboston, role = "roles/editor" }
    "hackhelp-editor"   = { folder = google_folder.hackathon_help.name, member = local.g.hackhelp, role = "roles/editor" }
    "infra-editor"      = { folder = google_folder.infrastructure.name, member = local.g.infra, role = "roles/editor" }
  }
}

resource "google_folder_iam_member" "folder" {
  for_each = local.folder_bindings
  folder   = each.value.folder
  member   = each.value.member
  role     = each.value.role
}

# ---------------- Central logging ----------------

resource "google_project" "logging" {
  name                = "Central Logging"
  project_id          = "pwl-central-logging"
  folder_id           = google_folder.common.name
  billing_account     = var.billing_account
  auto_create_network = false
  labels              = { business-unit = "operations" }
}

resource "google_logging_project_bucket_config" "org" {
  project        = google_project.logging.project_id
  location       = "global"
  bucket_id      = "org-audit-logs"
  retention_days = 90
}

resource "google_logging_organization_sink" "audit" {
  name             = "org-audit-logs"
  org_id           = var.org_id
  include_children = true
  destination      = "logging.googleapis.com/${google_logging_project_bucket_config.org.id}"
  filter           = "logName:\"cloudaudit.googleapis.com\""
}

resource "google_project_iam_member" "sink_writer" {
  project = google_project.logging.project_id
  role    = "roles/logging.bucketWriter"
  member  = google_logging_organization_sink.audit.writer_identity
}

# ---------------- Example workload projects ----------------

resource "google_project" "ganymede_sandbox" {
  name                = "Ganymede Sandbox"
  project_id          = "pwl-ganymede-sandbox"
  folder_id           = google_folder.ganymede_sandbox.name
  billing_account     = var.billing_account
  auto_create_network = false
  labels              = { business-unit = "programs", program = "ganymede", env = "sandbox" }
}

# ---------------- GAM project ----------------
# GAM's project was created by its installer. Keep it working by allowing
# service account key uploads there only. The import adopts the override
# that was already set with gcloud.

import {
  to = google_org_policy_policy.gam_key_upload
  id = "projects/gam-project-v4nn1/policies/iam.disableServiceAccountKeyUpload"
}

resource "google_org_policy_policy" "gam_key_upload" {
  name   = "projects/gam-project-v4nn1/policies/iam.disableServiceAccountKeyUpload"
  parent = "projects/gam-project-v4nn1"
  spec {
    rules { enforce = "FALSE" }
  }
}

# ---------------- Org policies ----------------

locals {
  enforced = [
    "iam.disableServiceAccountKeyCreation",
    "iam.automaticIamGrantsForDefaultServiceAccounts",
    "compute.skipDefaultNetworkCreation",
    "storage.uniformBucketLevelAccess",
  ]
}

# These three already exist as Google's secure-by-default policies.
# Adopt them instead of trying to create duplicates.
import {
  for_each = toset([
    "iam.disableServiceAccountKeyCreation",
    "iam.automaticIamGrantsForDefaultServiceAccounts",
    "storage.uniformBucketLevelAccess",
  ])
  to = google_org_policy_policy.enforced[each.value]
  id = "organizations/${var.org_id}/policies/${each.value}"
}

resource "google_org_policy_policy" "enforced" {
  for_each = toset(local.enforced)
  name     = "${local.org}/policies/${each.value}"
  parent   = local.org
  spec {
    rules { enforce = "TRUE" }
  }
}

# New orgs get domain restricted sharing by default.
# Open it up under Programs so Ganymede participants can use personal Google accounts.
resource "google_org_policy_policy" "ganymede_external" {
  name   = "${google_folder.programs.name}/policies/iam.allowedPolicyMemberDomains"
  parent = google_folder.programs.name
  spec {
    rules { allow_all = "TRUE" }
  }
}

# ---------------- Billing export ----------------
# Dataset only. Turning on the export itself is console-only:
# Billing > Billing export > BigQuery export > Standard usage cost.

resource "google_project_service" "logging_bigquery" {
  project            = google_project.logging.project_id
  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

resource "google_bigquery_dataset" "billing_export" {
  project     = google_project.logging.project_id
  dataset_id  = "billing_export"
  location    = "US"
  description = "Cloud Billing export, used for per business unit cost reporting"
  labels      = { business-unit = "operations" }

  depends_on = [google_project_service.logging_bigquery]
}
