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

  # Subtract the free tier only. Google applies it as a credit, so excluding all
  # credits counts free usage as spend. Other credits stay excluded, so real
  # usage still shows up even if a promo credit would cover it.
  budget_filter {
    credit_types_treatment = "INCLUDE_SPECIFIED_CREDITS"
    credit_types           = ["FREE_TIER"]
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
