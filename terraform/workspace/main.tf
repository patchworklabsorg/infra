# Organization units. Paths match the GAM script and the Workspace
# column of ad/org.json (Purgatory is the Workspace name for AD "Disabled").
locals {
  org_units = {
    staff = {
      name        = "Staff"
      parent      = "/"
      description = "Patchwork staff and volunteers with operational roles"
    }
    board_only = {
      name        = "Board-Only"
      parent      = "/"
      description = "Directors with no operational role"
    }
    service_accounts = {
      name        = "Service-Accounts"
      parent      = "/"
      description = "Non-human accounts for integrations"
    }
    purgatory = {
      name        = "Purgatory"
      parent      = "/"
      description = "Suspended users, all services off"
    }
    sponsored_projects = {
      name        = "Sponsored-Projects"
      parent      = "/"
      description = "Fiscally sponsored projects"
    }
    hackboston = {
      name        = "HackBoston"
      parent      = "/Sponsored-Projects"
      description = "HackBoston (hackboston.dev)"
    }
    hackathon_help = {
      name        = "hackathon.help"
      parent      = "/Sponsored-Projects"
      description = "hackathon.help"
    }
  }

  # Group addresses used by gcp-org/main.tf are marked.
  groups = {
    board = {
      email = "board@${var.primary_domain}" # gcp-org
      name  = "Board of Directors"
    }
    president = {
      email = "president@${var.primary_domain}"
      name  = "President"
    }
    treasurer = {
      email = "treasurer@${var.primary_domain}" # gcp-org
      name  = "Treasurer"
    }
    secretary = {
      email = "secretary@${var.primary_domain}"
      name  = "Secretary"
    }
    ganymede_admins = {
      email = "ganymede-admins@${var.primary_domain}" # gcp-org
      name  = "Ganymede Admins"
    }
    ganymede_users = {
      email                  = "ganymede-users@${var.primary_domain}"
      name                   = "Ganymede Users"
      allow_external_members = true
    }
    hackboston_organizers = {
      email = "organizers@hackboston.dev" # gcp-org
      name  = "HackBoston Organizers"
    }
    hackathon_help_organizers = {
      email = "organizers@hackathon.help" # gcp-org
      name  = "hackathon.help Organizers"
    }
    gcp_admins = {
      email = "gcp-admins@${var.primary_domain}" # gcp-org
      name  = "GCP Admins"
    }
    infra = {
      email = "infra@${var.primary_domain}" # gcp-org
      name  = "Infrastructure"
    }
  }

  memberships = merge(
    {
      for pair in flatten([
        for k, emails in var.group_members : [
          for e in emails : { key = "${k}/${e}", group = k, email = e, role = "MEMBER" }
        ]
      ]) : pair.key => pair
    },
    {
      for pair in flatten([
        for k, emails in var.group_owners : [
          for e in emails : { key = "${k}/${e}", group = k, email = e, role = "OWNER" }
        ]
      ]) : pair.key => pair
    },
  )
}

# Parents come first. The two sponsored project OUs depend on
# Sponsored-Projects through parent_org_unit_path, set below.
resource "googleworkspace_org_unit" "top" {
  for_each = { for k, v in local.org_units : k => v if v.parent == "/" }

  name                 = each.value.name
  description          = each.value.description
  parent_org_unit_path = each.value.parent
}

resource "googleworkspace_org_unit" "sponsored" {
  for_each = { for k, v in local.org_units : k => v if v.parent != "/" }

  name                 = each.value.name
  description          = each.value.description
  parent_org_unit_path = googleworkspace_org_unit.top["sponsored_projects"].org_unit_path
}

resource "googleworkspace_group" "this" {
  for_each = local.groups

  email       = each.value.email
  name        = each.value.name
  description = each.value.name
}

# Only the settings that the GAM script sets are managed here.
resource "googleworkspace_group_settings" "this" {
  for_each = { for k, v in local.groups : k => v if try(v.allow_external_members, false) }

  email                  = googleworkspace_group.this[each.key].email
  allow_external_members = true
}

resource "googleworkspace_group_member" "this" {
  for_each = local.memberships

  group_id = googleworkspace_group.this[each.value.group].id
  email    = each.value.email
  role     = each.value.role
}
