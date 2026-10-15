# terraform/github

This root manages the GitHub org `patchworklabsorg` with the `integrations/github` provider.

## What it manages

- Repositories: visibility, description, features, merge settings and default branch.
- Teams, team members and team access to repositories.
- Org members and their roles.
- Org settings in `settings.tf`, with the live values. The org does not require two-factor authentication. Members can create repositories.
- Rulesets on the default branch of `weave`, `infra`, `dns` and `core`.

It does not manage repo contents, secrets, Actions variables, webhooks or two-factor authentication.

Every repository has `prevent_destroy` and `archive_on_destroy = true`. Org members have `prevent_destroy`.

State is in the GCS bucket `pwl-tfstate`, prefix `github`.

## Auth

Never put a token in a file. The provider reads `GITHUB_TOKEN` from the environment.

```bash
export GITHUB_TOKEN="$(gh auth token)"
```

The token owner must be an owner of the org. Use one of these token types:

- Classic personal access token with the scopes `repo` and `admin:org`.
- Fine-grained token or GitHub App. Give it these permissions:
  - Repository: Administration (write), Metadata (read).
  - Organization: Members (write), Administration (write).

Rulesets with a `User` bypass actor and team changes need org owner rights.

You also need access to the GCS bucket. Run `gcloud auth application-default login`.

## First plan

The `import` blocks in `imports.tf` adopt the existing objects. The first plan must import them and change nothing.

1. Run `tofu init`.
2. Run `tofu plan`.
3. Check that the plan shows imports only. Fix `locals.tf` if it shows a change.
4. Run `tofu apply`.
5. Delete `imports.tf` in a later PR.

Expect small in-place updates on the first plan for provider-only fields, for example `archive_on_destroy`. The provider cannot read them from GitHub. These updates send the same values that GitHub already has.

Two things are not in the provider schema, so this root cannot manage them: the ruleset option `require_extra_approval_for_unattributed_changes` and the ruleset `dismissal_restriction`. Leave them as they are in the web UI.

## Add a repository

1. Add an entry to `local.repos` in `locals.tf`.
2. Run `tofu plan`. The plan creates the repository.
3. To give a team access, add the repository to `local.team_repos`.
4. To protect the default branch, add an entry to `local.rulesets`.

If the repository already exists, also add an `import` block for it.

## Add a team member

1. Add the user name and role to the team in `local.team_members`.
2. If the user is not in the org, add the user to `local.org_members` first.
3. Run `tofu plan` and `tofu apply`.

To add a team, add an entry to `local.teams`. Set `parent` to another team key or `null`.

## Drift

Settings that you change in the web UI show as drift in the next plan. The next apply reverts them. Make the change in `locals.tf` instead.
