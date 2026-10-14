locals {
  # Live values read from the org on 2026-10-14.
  # Keys are GitHub repository names.
  repos = {
    "krater" = {
      description = "The management utility for Project Ganymede"
      visibility  = "public"
      wiki        = false
      projects    = true
    }
    "quilt" = {
      description = "Central funding and records system for Patchwork Labs patches"
      visibility  = "private"
      wiki        = true
      projects    = true
    }
    "weave" = {
      description   = "The central identity provider for Patchwork Labs."
      visibility    = "public"
      homepage_url  = "https://weave.patchworklabs.org"
      wiki          = false
      projects      = false
      update_branch = true
      signoff       = true
    }
    "infra" = {
      description = "patchwork declarative infra"
      visibility  = "public"
      wiki        = false
      projects    = false
    }
    "infra-vault" = {
      description = "Ansible vault for patchworklabsorg/infra (private)"
      visibility  = "private"
      wiki        = true
      projects    = true
    }
    "patchworklabs.org" = {
      description  = ""
      visibility   = "public"
      homepage_url = "https://patchworklabs.org"
      wiki         = false
      projects     = false
    }
    "core" = {
      description    = "Services and other configuration on the Core VM running NixOS"
      visibility     = "public"
      default_branch = "trunk"
      archived       = true
      alerts         = false
      wiki           = false
      projects       = true
    }
    "internal-docs" = {
      description = "What each Patchwork Labs system is, and which names are taken"
      visibility  = "private"
      wiki        = true
      projects    = true
    }
    "selvage" = {
      description = ""
      visibility  = "private"
      wiki        = true
      projects    = true
    }
    "dns" = {
      description = "Declarative DNS Infrastructure for Patchwork Labs"
      visibility  = "public"
      wiki        = false
      projects    = false
    }
    "weave-kyc-propsal" = {
      description  = "VERY PRIVATE/INTERNAL - Jasper's proposal for weave kyc (not called kyc)"
      visibility   = "private"
      homepage_url = "https://weave-kyc-proposal.patchworklabs.org"
      wiki         = false
      projects     = false
    }
    ".github" = {
      description = ""
      visibility  = "private"
      # The repo is empty, so it has no default branch yet.
      default_branch = null
      wiki           = false
      projects       = true
      merge_commit   = true
      rebase_merge   = true
    }
    "slack" = {
      description    = "slack.patchworklabs.org (new domain soon?)"
      visibility     = "private"
      default_branch = null
      wiki           = false
      projects       = false
    }
  }

  # Org owners. Everyone else is a member.
  org_members = {
    "domvt"           = "admin"
    "jaspermayone"    = "admin"
    "taciturnaxolotl" = "admin"
    "Adambomb210"     = "member"
    "opticaldrive"    = "member"
    "pwlbot"          = "member"
  }

  # parent = key of another team in this map, or null.
  # team_id is the numeric ID, used only by the import blocks.
  teams = {
    "board-of-directors" = {
      name        = "Board of Directors"
      description = "Patchwork's Official Board of Directors"
      parent      = null
      team_id     = "13764277"
    }
    "dns-frens" = {
      name        = "dns-frens"
      description = "Maintainers of the Patchwork DNS"
      parent      = null
      team_id     = "13772583"
    }
    "infra" = {
      name        = "Infra"
      description = "Core team maintaining infra"
      parent      = null
      team_id     = "13772584"
    }
    "weave" = {
      name        = "Weave"
      description = "Parent Level team for our IDP (Weave) team"
      parent      = null
      team_id     = "14021296"
    }
    "weave-committers" = {
      name        = "weave-committers"
      description = "Core Weave (IDP) Team (merge access, etc)"
      parent      = "weave"
      team_id     = "14013373"
    }
    "weave-read" = {
      name        = "weave-read"
      description = "Read Only perms on Weave repos"
      parent      = "weave"
      team_id     = "14021309"
    }
    "weave-writers" = {
      name        = "weave-writers"
      description = "write level permissions on weave"
      parent      = "weave"
      team_id     = "14021259"
    }
  }

  root_teams  = { for k, v in local.teams : k => v if v.parent == null }
  child_teams = { for k, v in local.teams : k => v if v.parent != null }

  # team slug => github username => role (member or maintainer).
  team_members = {
    "board-of-directors" = { jaspermayone = "maintainer", domvt = "maintainer", taciturnaxolotl = "maintainer" }
    "dns-frens"          = { jaspermayone = "maintainer" }
    "infra"              = { jaspermayone = "maintainer" }
    "weave"              = { jaspermayone = "maintainer", Adambomb210 = "member" }
    "weave-committers"   = { jaspermayone = "maintainer" }
    "weave-read"         = { jaspermayone = "maintainer", Adambomb210 = "member" }
    "weave-writers"      = { jaspermayone = "maintainer", Adambomb210 = "member" }
  }

  # team slug => repo name => permission (pull, triage, push, maintain, admin).
  team_repos = {
    "board-of-directors" = { ".github" = "push", "internal-docs" = "pull" }
    "dns-frens"          = { "dns" = "push" }
    "infra"              = { "dns" = "maintain", "core" = "push", "infra" = "maintain" }
    "weave-committers"   = { "weave" = "maintain" }
    "weave-read"         = { "weave" = "pull" }
    "weave-writers"      = { "weave" = "push" }
  }

  team_member_pairs = merge([
    for team, users in local.team_members : {
      for user, role in users : "${team}/${user}" => { team = team, user = user, role = role }
    }
  ]...)

  team_repo_pairs = merge([
    for team, repos in local.team_repos : {
      for repo, permission in repos : "${team}/${repo}" => { team = team, repo = repo, permission = permission }
    }
  ]...)

  # One ruleset per repo, named "main". ruleset_id is used only by the import blocks.
  # reviewer_team = key of a team in local.teams, or null for no required reviewer.
  # actor_id null means the actor type has no ID (OrganizationAdmin).
  rulesets = {
    "weave" = {
      ruleset_id    = "8095206"
      include       = ["~DEFAULT_BRANCH", "refs/heads/main"]
      reviewer_team = "weave-committers"
      require_owner = true
      bypass = [
        { actor_type = "OrganizationAdmin", actor_id = null, bypass_mode = "always" },
        { actor_type = "User", actor_id = 65788728, bypass_mode = "exempt" },
      ]
    }
    "infra" = {
      ruleset_id    = "24858548"
      include       = ["~DEFAULT_BRANCH", "refs/heads/main"]
      reviewer_team = "infra"
      require_owner = true
      bypass = [
        { actor_type = "OrganizationAdmin", actor_id = null, bypass_mode = "always" },
        { actor_type = "User", actor_id = 65788728, bypass_mode = "exempt" },
      ]
    }
    "dns" = {
      ruleset_id    = "24858934"
      include       = ["~DEFAULT_BRANCH", "refs/heads/main"]
      reviewer_team = "dns-frens"
      require_owner = true
      bypass = [
        { actor_type = "OrganizationAdmin", actor_id = null, bypass_mode = "always" },
        { actor_type = "User", actor_id = 65788728, bypass_mode = "exempt" },
      ]
    }
    "core" = {
      ruleset_id    = "7227609"
      include       = ["~DEFAULT_BRANCH", "refs/heads/trunk"]
      reviewer_team = null
      require_owner = false
      bypass = [
        { actor_type = "OrganizationAdmin", actor_id = null, bypass_mode = "always" },
        { actor_type = "Integration", actor_id = 158384, bypass_mode = "always" },
      ]
    }
  }

  all_teams = merge(github_team.root, github_team.child)
}
