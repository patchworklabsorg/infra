# Zero-spend guard
# Alerts on the first cent of real usage, and feeds the kill switch in killswitch.tf.

resource "google_project_service" "logging_monitoring" {
  project            = google_project.logging.project_id
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
}

resource "google_monitoring_notification_channel" "security_email" {
  project      = google_project.logging.project_id
  display_name = "security@ email"
  type         = "email"
  labels = {
    email_address = "security@${var.domain}"
  }

  depends_on = [google_project_service.logging_monitoring]
}

resource "google_billing_budget" "zero_spend" {
  billing_account = var.billing_account
  display_name    = "Zero spend guard"

  amount {
    specified_amount {
      currency_code = "USD"
      units         = "1"
    }
  }

  # Ignore credits so any real usage shows up, even if a credit would cover it.
  budget_filter {
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
  }

  threshold_rules {
    threshold_percent = 0.01 # first cent
  }
  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 1.0
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.security_email.id]
    disable_default_iam_recipients   = false
    pubsub_topic                     = google_pubsub_topic.budget.id
    schema_version                   = "1.0"
  }

  depends_on = [google_pubsub_topic_iam_member.billing_publisher]
}
