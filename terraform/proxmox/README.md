# terraform/proxmox

This root manages the Patchwork NixOS VMs on the Proxmox node `pve01`. It uses the `bpg/proxmox` provider.

## What it manages

| Host | VMID | Address | Memory |
|---|---|---|---|
| `warp` | 356 | 10.100.90.56 | 6 GB |
| `skein` | 355 | 10.100.90.55 | 4 GB |
| `seam` | 357 | 10.100.90.57 | 2 GB |
| `hem` | 358 | 10.100.90.58 | 2 GB |

Each VM matches `hosts/proxmox-vm.nix`:

- SeaBIOS, `virtio-scsi-single`, one disk `scsi0` (`/dev/sda` in the guest).
- CPU type `host`. The QEMU guest agent is on.
- The disk is on `trunk-vms`. The pool `local-zfs` is full.
- The NIC is on the SDN vnet `pwpriv`. This vnet carries VLAN 90, so the root sets no VLAN tag.

The root sets the VM hardware only. The address is not set in Proxmox. NixOS sets it. The `ip` field in the map is a record, and the output shows it.

Cores and disk sizes in `variables.tf` are starting values. Check them before the first apply.

## Not managed

The Windows VMs `loom` (310), `spindle` (311), `bobbin` (312) and `shuttle` (314) are not in this root. Ansible manages their contents. They can be imported later.

## State

The state is in the GCS bucket `pwl-tfstate`, prefix `proxmox`.

## Token

Use a dedicated API token. Do not reuse the `ansible@pve!provision` token.

1. Create a user, for example `terraform@pve`, and a token with privilege separation: `pveum user token add terraform@pve patchwork --privsep 1`.
2. Create a pool, for example `patchwork`. Put the four VMs in it.
3. Create a role with these privileges:
   `VM.Allocate VM.Audit VM.Config.CDROM VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt VM.GuestAgent.Audit Sys.Audit Pool.Audit`
4. Give the role to the user and to the token on `/pool/patchwork`.
5. Give the same role access to these paths:
   - `/storage/trunk-vms` with `Datastore.Audit Datastore.AllocateSpace`.
   - `/storage/local` with `Datastore.Audit`, to read the ISO.
   - `/sdn/zones/<zone>/pwpriv` with `SDN.Use`. Use `SDN.Audit` on `/sdn`.
   - `/nodes/pve01` with `Sys.Audit`.

A privilege-separated token cannot hold more than its user. Give the privileges to the user and to the token. The token does not need `VM.Clone`, `Sys.Modify` or any SDN write privilege.

## Environment variables

| Variable | Value |
|---|---|
| `PROXMOX_VE_API_TOKEN` | `terraform@pve!patchwork=<secret>` |
| `PROXMOX_VE_INSECURE` | `true`, while pve01 uses a self-signed certificate |
| `GOOGLE_APPLICATION_CREDENTIALS` or `gcloud auth application-default login` | Access to the state bucket |

Do not write the token in a file or in a tfvars file.

## Plan

Set the required variables in a `terraform.tfvars` file that git ignores, or pass them with `-var`.

```bash
cat > terraform.tfvars <<'VARS'
proxmox_endpoint      = "https://<pve01-address>:8006/"
installer_iso_file_id = "local:iso/<nixos-installer>.iso"
VARS
terraform init && terraform plan
```

Do not apply before you read the plan.

## Existing VMs

If a VM exists, uncomment its `import` block in `main.tf` before the first plan. Then run the plan. The plan must show no destroy. The provider can show small differences in disk or NIC settings. Adjust the map or the resource until the plan is clean.

The resource has `prevent_destroy`. It ignores the CD-ROM, the boot order, the power state, the description and the tags. You detach the ISO after the install, and Terraform leaves it alone.

## Add a host

1. Add the host to `hosts` in `flake.nix`.
2. Add the host to `linuxHosts` in `ad/org.json`.
3. Add an entry to the `vms` map in `variables.tf`.
4. Add a commented `import` block if the VM already exists.
5. Plan, apply, then install with nixos-anywhere from the installer ISO.

## Memory warning

pve01 has no swap. If the node runs out of memory, the OOM killer stops a guest. Check the committed memory before you add or grow a VM. On 2026-08-25, pve01 had 121 of 125.8 GiB committed. Keep at least 4 GiB of available memory after the VM boots. Count available memory, not free memory. Free memory excludes the reclaimable page cache.
