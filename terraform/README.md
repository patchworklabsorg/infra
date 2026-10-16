# terraform

Terraform roots for Patchwork Labs. Each root is one directory with its own state.

## Which tool owns what

Use one tool for each thing. Never manage one thing with two tools.

| Tool | Owns |
|---|---|
| Terraform | Resources that an API creates and deletes. |
| Ansible | Configuration of the Windows hosts, AD and thimble. |
| NixOS | Configuration of the Linux hosts. |

## Roots

| Root | Manages |
|---|---|
| `gcp-org/` | The Google Cloud organization: budget, kill switch and PAM. |
| `proxmox/` | Proxmox VMs. |
| `workspace/` | Google Workspace. |
| `github/` | The GitHub organization. |

The `gcp-org` root exists now. The other roots come from separate changes.

## State

Every root uses the GCS backend. The bucket is `pwl-tfstate`. The prefix is the name of the root, for example `gcp-org`.

## Credentials

Credentials come only from environment variables or `gcloud`. Never put credentials in a file in this repo.

The file `terraform.tfvars` is git-ignored. So are `*.auto.tfvars`, `.terraform/` and `*.tfstate*`. See `terraform/.gitignore`.

## Workspace service account

The `gcp-org` root creates the service account `tf-workspace`. The `workspace/` root impersonates it to manage Google Workspace. The account has no keys.

The group `gcp-admins` has `roles/iam.serviceAccountTokenCreator` on the account.

A super admin must add domain-wide delegation by hand. Terraform cannot do this step. Open the Admin console, go to Security, Access and data control, API controls, Domain-wide delegation. Add the client ID from the output `tf_workspace_service_account_client_id` with these scopes:

- `https://www.googleapis.com/auth/admin.directory.orgunit`
- `https://www.googleapis.com/auth/admin.directory.group`
- `https://www.googleapis.com/auth/admin.directory.group.member`
- `https://www.googleapis.com/auth/apps.groups.settings`

## Commands

Run the format check from the repo root with `nix flake check`. Enter the dev shell with `nix develop`. The shell has `tofu` and `gcloud`.

For `gcp-org`, run `./tf <command>` in `terraform/gcp-org/`. The wrapper asks PAM for access before any command that writes.
