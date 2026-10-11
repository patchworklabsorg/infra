# Billing kill switch
# Budget notifications go to Pub/Sub, a small Cloud Run function reads them,
# and once actual spend hits the budget it unlinks billing from every project
# under Programs and Sponsored Projects. Common and Operations are never touched,
# so logging and this function keep running.

locals {
  guard_project = google_project.logging.project_id
  guard_region  = "us-east1"
  guard_folders = [google_folder.programs.name, google_folder.sponsored.name]
  guard_apis = [
    "artifactregistry.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "eventarc.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
  ]
}

resource "google_project_service" "guard" {
  for_each           = toset(local.guard_apis)
  project            = local.guard_project
  service            = each.value
  disable_on_destroy = false
}

# ---------- Pub/Sub ----------

resource "google_pubsub_topic" "budget" {
  project    = local.guard_project
  name       = "billing-budget-alerts"
  depends_on = [google_project_service.guard]
}

# Domain restricted sharing blocks Google's own billing system account, since it
# isn't in our Workspace customer. Allow it on this one project only, so Cloud
# Billing can publish budget notifications to the topic.
resource "google_org_policy_policy" "guard_drs_exception" {
  name   = "projects/${local.guard_project}/policies/iam.allowedPolicyMemberDomains"
  parent = "projects/${local.guard_project}"
  spec {
    rules { allow_all = "TRUE" }
  }
}

# Org policy changes take a minute or two to propagate.
resource "time_sleep" "guard_drs_propagation" {
  depends_on      = [google_org_policy_policy.guard_drs_exception]
  create_duration = "90s"
}

# Cloud Billing publishes budget notifications as this system account.
resource "google_pubsub_topic_iam_member" "billing_publisher" {
  project    = local.guard_project
  topic      = google_pubsub_topic.budget.name
  role       = "roles/pubsub.publisher"
  member     = "serviceAccount:billing-budget-alert@system.gserviceaccount.com"
  depends_on = [time_sleep.guard_drs_propagation]
}

# ---------- Service accounts ----------

resource "google_service_account" "guard" {
  project      = local.guard_project
  account_id   = "billing-guard"
  display_name = "Billing kill switch"
}

resource "google_service_account" "guard_builder" {
  project      = local.guard_project
  account_id   = "billing-guard-builder"
  display_name = "Billing kill switch build"
}

resource "google_project_iam_member" "guard_builder" {
  project = local.guard_project
  role    = "roles/cloudbuild.builds.builder"
  member  = google_service_account.guard_builder.member
}

resource "google_project_iam_member" "guard_runtime" {
  for_each = toset(["roles/run.invoker", "roles/eventarc.eventReceiver", "roles/logging.logWriter"])
  project  = local.guard_project
  role     = each.value
  member   = google_service_account.guard.member
}

# What the switch is allowed to touch: list and unlink projects under these folders only.
resource "google_folder_iam_member" "guard" {
  for_each = {
    for pair in setproduct(local.guard_folders, ["roles/browser", "roles/billing.projectManager"]) :
    "${pair[0]}-${pair[1]}" => { folder = pair[0], role = pair[1] }
  }
  folder = each.value.folder
  role   = each.value.role
  member = google_service_account.guard.member
}

# ---------- Function source ----------

resource "google_storage_bucket" "guard_src" {
  project                     = local.guard_project
  name                        = "pwl-billing-guard-src"
  location                    = "US"
  uniform_bucket_level_access = true
  force_destroy               = true
  depends_on                  = [google_project_service.guard]
}

data "archive_file" "guard" {
  type        = "zip"
  source_dir  = "${path.module}/billing-guard"
  output_path = "${path.module}/.build/billing-guard.zip"
}

resource "google_storage_bucket_object" "guard" {
  bucket = google_storage_bucket.guard_src.name
  name   = "billing-guard-${data.archive_file.guard.output_md5}.zip"
  source = data.archive_file.guard.output_path
}

# ---------- Function ----------

resource "google_cloudfunctions2_function" "guard" {
  project  = local.guard_project
  location = local.guard_region
  name     = "billing-guard"

  build_config {
    runtime         = "python312"
    entry_point     = "guard"
    service_account = google_service_account.guard_builder.id
    source {
      storage_source {
        bucket = google_storage_bucket.guard_src.name
        object = google_storage_bucket_object.guard.name
      }
    }
  }

  service_config {
    max_instance_count    = 1
    available_memory      = "256M"
    timeout_seconds       = 120
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    service_account_email = google_service_account.guard.email
    environment_variables = {
      TARGET_FOLDERS = join(",", local.guard_folders)
      TRIP_RATIO     = "1.0"
      DRY_RUN        = "false"
    }
  }

  event_trigger {
    trigger_region        = local.guard_region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.budget.id
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.guard.email
  }

  depends_on = [
    google_project_iam_member.guard_builder,
    google_project_iam_member.guard_runtime,
  ]
}
