# terraform/workspace

Terraform root for the Patchwork Labs Google Workspace. The primary domain is `patchworklabs.org`. The secondary domains are `hackboston.dev` and `hackathon.help`.

## What it manages

- Org units: `/Staff`, `/Board-Only`, `/Service-Accounts`, `/Purgatory`, `/Sponsored-Projects` and its two children.
- Groups: board, president, treasurer, secretary, ganymede-admins, ganymede-users, the two organizers groups, gcp-admins and infra.
- Group settings: only `allow_external_members` on `ganymede-users`. This is the one setting that the GAM script sets.
- Group memberships: only the ones you list in `group_members` and `group_owners`.

## What it leaves out

| Item | Owner | Why |
|---|---|---|
| User accounts and their attributes (OU placement, title, department) | Weave | Weave is the source of truth for people. It creates the users. |
| Domains and domain verification | GAM, by hand | The `domains` and `verify` phases of `workspace/patchwork-workspace-setup.sh` need DNS records. |
| Memberships of person addresses in git | You, by variable | See the next section. |

## Memberships

The module takes memberships as variables. It does not commit any address.

- `group_members` is a map of group key to a list of emails.
- `group_owners` has the same shape. It sets the `OWNER` role.
- The group key is a key of `local.groups` in `main.tf`, for example `board`.
- A group with no entry has no managed members. Terraform does not remove members that you do not list.

Why this choice: the GAM script adds people to groups, and Weave will create the people. Real addresses must not be in a public-style repo. A variable keeps the addresses in a local `.tfvars` file or in `TF_VAR_group_members`. The `.gitignore` here ignores `*.tfvars`. If Weave later manages group membership, leave both variables empty.

Example, with placeholders:

```hcl
group_members = {
  board     = ["person-one@example.org", "person-two@example.org"]
  president = ["person-one@example.org"]
}
```

## Authentication

No credential is in a file. The provider uses Application Default Credentials.

1. Pick a service account with domain-wide delegation for the scopes in `versions.tf`.
2. Run `gcloud auth application-default login --impersonate-service-account=<SERVICE_ACCOUNT_EMAIL>`.
3. Set `GOOGLEWORKSPACE_IMPERSONATED_USER_EMAIL` to a super admin address.
4. Set `GOOGLEWORKSPACE_SERVICE_ACCOUNT` to the service account email.
5. Give your identity read and write access to the state bucket `pwl-tfstate`.

Do not store service account key files in this repository.

## Variables

| Name | Meaning |
|---|---|
| `customer_id` | Workspace customer ID (`C0...`). Required. Pass it with `-var` or `TF_VAR_customer_id`. |
| `primary_domain` | Default `patchworklabs.org`. |
| `group_members`, `group_owners` | See Memberships. |

## First plan

The GAM script already created the OUs and the groups. Import them so Terraform does not try to create them again.

1. Authenticate as described above.
2. Run `tofu init`.
3. Read the IDs with `gam select patchwork print orgs allfields` and `gam select patchwork print groups`.
4. Open `imports.tf`. Remove the leading `# ` from each block and set the real ID.
5. Run `tofu plan -var customer_id=C0XXXXXXX`.
6. Check that the plan shows imports. It must show no create for an item that exists.
7. Run `tofu apply` only after review.

Terraform sets OU descriptions and group descriptions on the first apply. The group description equals the group name. This can show as a small in-place update.

## How names line up

| Source | Name |
|---|---|
| `ad/org.json` `roleGroups` | `GG-Board`, `GG-President`, `GG-Treasurer`, `GG-Secretary`, `GG-Ganymede-Admins`, `GG-Ganymede-Users`, `GG-HackBoston-Organizers`, `GG-HackathonHelp-Organizers`, `GG-Infra` |
| This root | `board@`, `president@`, `treasurer@`, `secretary@`, `ganymede-admins@`, `ganymede-users@`, `organizers@hackboston.dev`, `organizers@hackathon.help`, `infra@` |
| `gcp-org/main.tf` | Reads `board@`, `treasurer@`, `ganymede-admins@`, `gcp-admins@`, `infra@`, `organizers@hackboston.dev`, `organizers@hackathon.help` |

- Group addresses in this root must stay equal to the addresses in `gcp-org`. Change both in one pull request.
- `GG-Domain-Admins-Tier0` and the `lnx-*` host groups are AD only. They have no Workspace group.
- The Workspace OUs match the `Users/...` OUs of `ad/org.json`, without the `Users/` prefix. `Purgatory` in Workspace is `Disabled` in AD.
- The division and department names (Programs, Project Ganymede, Governance, Operations) in `ad/org.json` are user attributes. Weave sets them.
