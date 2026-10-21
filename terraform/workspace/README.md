# terraform/workspace

Terraform root for the Patchwork Labs Google Workspace. The primary domain is `patchworklabs.org`. The secondary domains are `hackboston.dev` and `hackathon.help`.

## What it manages

- Org units: `/Staff`, `/Board-Only`, `/Service-Accounts`, `/Purgatory`, `/Sponsored-Projects` and its two children.
- Groups: board, president, treasurer, secretary, ganymede-admins, ganymede-users, the two organizers groups, gcp-admins and infra.
- Group settings: only `allow_external_members` on `ganymede-users`. This is the one setting that the GAM script sets.

## What it leaves out

| Item | Owner | Why |
|---|---|---|
| User accounts and their attributes (OU placement, title, department) | Weave | Weave is the source of truth for people. It creates the users. |
| Domains and domain verification | GAM, by hand | The `domains` and `verify` phases of `workspace/patchwork-workspace-setup.sh` need DNS records. |
| Group memberships | Weave | Weave owns users and memberships. |

## Memberships

Weave owns users and group memberships. This root manages the groups only. It has no membership resources and no membership variables. It does not add or remove members.

## Authentication

No credential is in a file. The provider uses Application Default Credentials and impersonates a service account.

The service account is `tf-workspace@<SEED_PROJECT>.iam.gserviceaccount.com`. The root `terraform/gcp-org` creates it. The output `tf_workspace_service_account_email` shows the address. Members of `gcp-admins` have `roles/iam.serviceAccountTokenCreator` on it. A super admin must add domain-wide delegation for the scopes in `versions.tf`. See `terraform/README.md`.

1. Run `gcloud auth application-default login --impersonate-service-account=tf-workspace@<SEED_PROJECT>.iam.gserviceaccount.com`.
2. Set `GOOGLEWORKSPACE_IMPERSONATED_USER_EMAIL` to a super admin address.
3. Set `GOOGLEWORKSPACE_SERVICE_ACCOUNT` to the service account email.
4. Give your identity read and write access to the state bucket `pwl-tfstate`.

Do not create keys for the service account. The org policy blocks them.

## Variables

| Name | Meaning |
|---|---|
| `customer_id` | Workspace customer ID (`C0...`). Required. Pass it with `-var` or `TF_VAR_customer_id`. |
| `primary_domain` | Default `patchworklabs.org`. |

## First plan

The GAM script already created the OUs and the groups. Import them so Terraform does not try to create them again.

1. Authenticate as described above.
2. Run `tofu init`.
3. Read the IDs with `gam select patchwork print orgs allfields` and `gam select patchwork print groups`.
4. Open `imports.tf`. Remove the leading `# ` from each block and set the real ID.
5. Run `tofu plan -var customer_id=C0XXXXXXX`.
6. Check that the plan shows imports. It must show no create for an item that exists.
7. Run `tofu apply` only after review.

Terraform sets OU descriptions and group descriptions on the first apply. Each group has a one-line description. This can show as a small in-place update.

## How names line up

| Source | Name |
|---|---|
| `ad/org.json` `roleGroups` | `board`, `president`, `treasurer`, `secretary`, `ganymede-admins`, `ganymede-users`, `hackboston-organizers`, `hackathonhelp-organizers`, `infra` |
| This root | `board@`, `president@`, `treasurer@`, `secretary@`, `ganymede-admins@`, `ganymede-users@`, `organizers@hackboston.dev`, `organizers@hackathon.help`, `infra@` |
| `gcp-org/main.tf` | Reads `board@`, `treasurer@`, `ganymede-admins@`, `gcp-admins@`, `infra@`, `organizers@hackboston.dev`, `organizers@hackathon.help` |

- Group addresses in this root must stay equal to the addresses in `gcp-org`. Change both in one pull request.
- `tier0-admins` and the `lnx-*` host groups are AD only. They have no Workspace group.
- The Workspace OUs match the `Users/...` OUs of `ad/org.json`, without the `Users/` prefix. `Purgatory` in Workspace is `Disabled` in AD.
- The division and department names (Programs, Project Ganymede, Governance, Operations) in `ad/org.json` are user attributes. Weave sets them.
