resource "github_repository" "repo" {
  for_each = local.repos

  name         = each.key
  description  = each.value.description
  visibility   = each.value.visibility
  homepage_url = try(each.value.homepage_url, null)
  archived     = try(each.value.archived, false)

  has_issues      = true
  has_wiki        = each.value.wiki
  has_projects    = each.value.projects
  has_discussions = false
  is_template     = false

  allow_merge_commit     = try(each.value.merge_commit, false)
  allow_squash_merge     = true
  allow_rebase_merge     = try(each.value.rebase_merge, false)
  allow_auto_merge       = false
  allow_update_branch    = try(each.value.update_branch, false)
  delete_branch_on_merge = false

  squash_merge_commit_title   = "COMMIT_OR_PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"
  merge_commit_title          = "MERGE_MESSAGE"
  merge_commit_message        = "PR_TITLE"

  web_commit_signoff_required = try(each.value.signoff, false)
  vulnerability_alerts        = try(each.value.alerts, true)

  archive_on_destroy = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "github_branch_default" "repo" {
  for_each = { for k, v in local.repos : k => v if try(v.default_branch, "main") != null }

  repository = github_repository.repo[each.key].name
  branch     = try(each.value.default_branch, "main")
}

resource "github_team" "root" {
  for_each = local.root_teams

  name                 = each.value.name
  description          = each.value.description
  privacy              = "closed"
  notification_setting = "notifications_enabled"
}

resource "github_team" "child" {
  for_each = local.child_teams

  name                 = each.value.name
  description          = each.value.description
  privacy              = "closed"
  notification_setting = "notifications_enabled"
  parent_team_id       = github_team.root[each.value.parent].id
}

resource "github_membership" "member" {
  for_each = local.org_members

  username = each.key
  role     = each.value

  lifecycle {
    prevent_destroy = true
  }
}

resource "github_team_membership" "member" {
  for_each = local.team_member_pairs

  team_id  = local.all_teams[each.value.team].id
  username = each.value.user
  role     = each.value.role
}

resource "github_team_repository" "access" {
  for_each = local.team_repo_pairs

  team_id    = local.all_teams[each.value.team].id
  repository = github_repository.repo[each.value.repo].name
  permission = each.value.permission
}

resource "github_repository_ruleset" "main" {
  for_each = local.rulesets

  name        = "main"
  repository  = github_repository.repo[each.key].name
  target      = "branch"
  enforcement = "active"

  dynamic "bypass_actors" {
    for_each = each.value.bypass
    content {
      actor_type  = bypass_actors.value.actor_type
      actor_id    = bypass_actors.value.actor_id
      bypass_mode = bypass_actors.value.bypass_mode
    }
  }

  conditions {
    ref_name {
      include = each.value.include
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      allowed_merge_methods             = ["squash"]
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = each.value.require_owner
      require_last_push_approval        = true
      required_approving_review_count   = 1
      required_review_thread_resolution = true

      dynamic "required_reviewers" {
        for_each = each.value.reviewer_team == null ? [] : [each.value.reviewer_team]
        content {
          file_patterns     = ["*"]
          minimum_approvals = 1
          reviewer {
            id   = tonumber(local.all_teams[required_reviewers.value].id)
            type = "Team"
          }
        }
      }
    }
  }
}
