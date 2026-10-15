# Privileged Access Manager
# Just-in-time elevation instead of standing admin roles.
# Requests get logged in the org audit sink and emailed to security@.

locals {
  org_resource      = "//cloudresourcemanager.googleapis.com/organizations/${var.org_id}"
  org_resource_type = "cloudresourcemanager.googleapis.com/Organization"
  pam_notify        = ["security@${var.domain}"]
}

# PAM's org service agent needs this role before entitlements work.
resource "google_organization_iam_member" "pam_service_agent" {
  org_id = var.org_id
  role   = "roles/privilegedaccessmanager.organizationServiceAgent"
  member = "serviceAccount:service-org-${var.org_id}@gcp-sa-pam.iam.gserviceaccount.com"
}

# Day-to-day infra work: folders and new projects. Justification only, no approval.
resource "google_privileged_access_manager_entitlement" "infra" {
  entitlement_id       = "infra-admin"
  location             = "global"
  parent               = "organizations/${var.org_id}"
  max_request_duration = "14400s"

  eligible_users {
    principals = [local.g.admins]
  }

  privileged_access {
    gcp_iam_access {
      resource      = local.org_resource
      resource_type = local.org_resource_type
      role_bindings {
        role = "roles/resourcemanager.folderAdmin"
      }
      role_bindings {
        role = "roles/resourcemanager.projectCreator"
      }
      role_bindings {
        role = "roles/billing.projectManager"
      }
    }
  }

  requester_justification_config {
    unstructured {}
  }

  additional_notification_targets {
    admin_email_recipients = local.pam_notify
  }

  depends_on = [google_organization_iam_member.pam_service_agent]
}

# Full org control. Justification only, no approval step.
# Every grant is emailed to security@ and lands in the audit sink.
resource "google_privileged_access_manager_entitlement" "org_admin" {
  entitlement_id       = "org-admin"
  location             = "global"
  parent               = "organizations/${var.org_id}"
  max_request_duration = "3600s"

  eligible_users {
    principals = [local.g.admins]
  }

  privileged_access {
    gcp_iam_access {
      resource      = local.org_resource
      resource_type = local.org_resource_type
      role_bindings {
        role = "roles/resourcemanager.organizationAdmin"
      }
      role_bindings {
        role = "roles/orgpolicy.policyAdmin"
      }
    }
  }

  requester_justification_config {
    unstructured {}
  }


  additional_notification_targets {
    admin_email_recipients = local.pam_notify
  }

  depends_on = [google_organization_iam_member.pam_service_agent]
}
