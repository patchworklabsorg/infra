# These objects already exist. The import blocks adopt them into state.
# After the first apply, you may delete this file.
#
# A repository entry with `exists = false` is new: the plan creates it and must not import it.
# Importing a name that GitHub does not know fails the whole plan.

import {
  for_each = { for k, v in local.repos : k => v if try(v.exists, true) }
  to       = github_repository.repo[each.key]
  id       = each.key
}

import {
  for_each = { for k, v in local.repos : k => v if try(v.exists, true) && try(v.default_branch, "main") != null }
  to       = github_branch_default.repo[each.key]
  id       = each.key
}

import {
  for_each = local.root_teams
  to       = github_team.root[each.key]
  id       = each.value.team_id
}

import {
  for_each = local.child_teams
  to       = github_team.child[each.key]
  id       = each.value.team_id
}

import {
  for_each = local.org_members
  to       = github_membership.member[each.key]
  id       = each.key
}

import {
  for_each = local.team_member_pairs
  to       = github_team_membership.member[each.key]
  id       = "${local.teams[each.value.team].team_id}:${each.value.user}"
}

import {
  for_each = local.team_repo_pairs
  to       = github_team_repository.access[each.key]
  id       = "${local.teams[each.value.team].team_id}:${each.value.repo}"
}

import {
  for_each = local.rulesets
  to       = github_repository_ruleset.main[each.key]
  id       = "${each.key}:${each.value.ruleset_id}"
}

# The ID is the numeric ID of the organization.
import {
  to = github_organization_settings.this
  id = "216448207"
}
