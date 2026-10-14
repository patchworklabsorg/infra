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

## Commands

Run the format check from the repo root with `nix flake check`. Enter the dev shell with `nix develop`. The shell has `tofu` and `gcloud`.

For `gcp-org`, run `./tf <command>` in `terraform/gcp-org/`. The wrapper asks PAM for access before any command that writes.
