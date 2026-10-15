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

## Tier 0 jump host `spool`

`windows.tf` adds `spool`, the Tier 0 jump host from `ad/TIERING.md` (decision 3). It is a separate resource, because it is Windows and not NixOS.

| Host | VMID | Address | Memory | Cores | Disk |
|---|---|---|---|---|---|
| `spool` | 359 (confirm free) | 10.100.90.59 (confirm free) | 4 GB | 2 | 60 GB |

- OVMF (UEFI) with pre-enrolled Secure Boot keys, a TPM 2.0 state disk, machine `q35`, OS type `win11` (Windows 11 and Server 2022/2025).
- The disk is `sata0` and the NIC is `e1000e`. The Windows installer has drivers for both, so you do not need the virtio-win ISO.
- The guest agent is off in Proxmox until you install it in Windows. Then set `agent.enabled = true` by hand in Proxmox. Terraform ignores the change.
- No VM is created while `create_spool` is false and `windows_iso_file_id` is null. The NixOS VMs do not need these variables.

### Windows ISO

With `create_spool = true`, Terraform makes Proxmox download the Windows Server 2025 evaluation ISO to `local:iso/windows-server-2025-eval.iso`. The resource is `proxmox_virtual_environment_download_file.windows_installer`.

- The URL is the variable `windows_iso_url`. The default is the Microsoft fwlink `https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us`. It comes from the Microsoft Evaluation Center (English, x64).
- The fwlink redirects to the file `26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso`. It is 6014152704 bytes (about 5.6 GiB). Microsoft can publish a newer build behind the same link.
- The resource sets `overwrite = false`, so a later plan does not download the file again.
- The upload timeout is two hours.
- To use an ISO that is already on the node, set `windows_iso_file_id`. It overrides the download.

License: this is the evaluation edition. It runs for 180 days. Activate it over the internet in the first 10 days, or it shuts down. To keep it, convert it to a retail or volume edition with a valid key (`DISM /Online /Set-Edition`). Plan the conversion before day 180.

### Create spool

1. Check that VMID 359 and 10.100.90.59 are free: `pvesh get /cluster/resources --type vm` on pve01, and `Resolve-DnsName 10.100.90.59` or a ping in the lab.
2. Check the committed memory on pve01 (see "Memory warning").
3. Plan only the Windows resources: `tofu plan -var create_spool=true -target=proxmox_virtual_environment_download_file.windows_installer -target=proxmox_virtual_environment_vm.spool`
4. Read the plan. Then run the same command with `apply`.
5. Open the console of VMID 359 in Proxmox. Boot from the ISO. Choose "Windows Server 2025 Standard Evaluation (Desktop Experience)", or the Core option if `ad/TIERING.md` says Core. Use the SATA disk. Do not load drivers.
6. Set the static address. Join the domain `patchwork.internal` and put the computer in `OU=Servers,OU=Patchwork`.
7. Turn off NLA for Remote Desktop and limit the Windows firewall as `ad/TIERING.md` says.
8. Run `converge.ps1` Build. `spool` is already in `tiering.computers` in `ad/org.json`, so Build adds `SPOOL$` to T0-Silo.
9. After the install, detach the ISO. Terraform ignores the CD-ROM and boot order.

Keep `create_spool = true` in later runs. If you set it to false, the plan destroys the ISO resource and the VM. The VM has `prevent_destroy`, so the plan fails.

The token needs `VM.Config.Disk` on the pool for the EFI and TPM disks. It has it.

## Not managed

The Windows VMs `loom` (310), `spindle` (311), `bobbin` (312) and `shuttle` (314) are not in this root. Ansible manages their contents. They can be imported later.

## State

The state is in the GCS bucket `pwl-tfstate`, prefix `proxmox`.

## Token

Use a dedicated API token. Do not reuse the `ansible@pve!provision` token.

1. Create a user, for example `terraform@pve`, and a token with privilege separation: `pveum user token add terraform@pve patchwork --privsep 1`.
2. Use the pool `patchwork`. It exists. Each VM sets `pool_id` to it.
3. Create a role with these privileges:
   `VM.Allocate VM.Audit VM.Config.CDROM VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt VM.GuestAgent.Audit Sys.Audit Pool.Audit`
4. Give the role to the user and to the token on `/pool/patchwork`.
5. Give the same role access to these paths:
   - `/storage/trunk-vms` with `Datastore.Audit Datastore.AllocateSpace`.
   - `/storage/local` with `Datastore.Audit Datastore.AllocateTemplate`, to download the ISO.
   - `/sdn/zones/<zone>/pwpriv` with `SDN.Use`. Use `SDN.Audit` on `/sdn`.
   - `/nodes/pve01` with `Sys.Audit`.

A privilege-separated token cannot hold more than its user. Give the privileges to the user and to the token. The token does not need `VM.Clone`, `Sys.Modify` or any SDN write privilege.

## Endpoint

The default endpoint is `https://proxmox.hogwarts.dev/`. It is behind Cloudflare. A request to `/api2/json/version` returns 301. Port 8006 does not answer from outside.

The API path may be behind Cloudflare Access. If it is, the provider cannot reach the API with only the API token. In that case, override the endpoint with the LAN address of pve01 over the VPN:

```bash
terraform plan -var proxmox_endpoint=https://<pve01-lan-address>:8006/
```

## Environment variables

| Variable | Value |
|---|---|
| `PROXMOX_VE_API_TOKEN` | `terraform@pve!patchwork=<secret>` |
| `PROXMOX_VE_INSECURE` | `true`, while pve01 uses a self-signed certificate |
| `GOOGLE_APPLICATION_CREDENTIALS` or `gcloud auth application-default login` | Access to the state bucket |

Do not write the token in a file or in a tfvars file.

## Plan

All variables have defaults. To override one, use a `terraform.tfvars` file that git ignores, or pass `-var`.

```bash
cat > terraform.tfvars <<'VARS'
proxmox_endpoint = "https://<pve01-lan-address>:8006/" # optional, see Endpoint
VARS
terraform init && terraform plan
```

Do not apply before you read the plan.

## Installer ISO

The root uploads the Patchwork installer ISO to `local` storage on `pve01`. The VMs boot from it. The ISO is the NixOS minimal ISO with the admin SSH keys on root, so nixos-anywhere connects at once. It also runs the QEMU guest agent, so `tofu output ipv4_addresses` shows the DHCP address.

Build the ISO before you apply:

```bash
nix build .#installer-iso -o result-installer
```

The build needs an x86_64-linux builder. The variable `installer_iso_path` points to the file. The default is `../../result-installer/iso/patchwork-nixos-installer.iso`.

The guest agent wait is 2 minutes (`agent.timeout`). A VM without an agent does not stall an apply for 15 minutes.

The old resource `proxmox_virtual_environment_download_file.nixos_installer` is gone. A `removed` block forgets it in the state and keeps the stock ISO on the node. The CD-ROM of existing VMs is in `ignore_changes`, so the plan does not touch them. Delete the old ISO file by hand when no VM uses it. This needs OpenTofu 1.7 or newer.

## Existing VMs

No VM exists yet. The import blocks in `main.tf` are for later only. If a VM exists, uncomment its `import` block in `main.tf` before the first plan. Then run the plan. The plan must show no destroy. The provider can show small differences in disk or NIC settings. Adjust the map or the resource until the plan is clean.

The resource has `prevent_destroy`. It ignores the CD-ROM, the boot order, the power state, the description and the tags. You detach the ISO after the install, and Terraform leaves it alone.

## Add a host

1. Add the host to `hosts` in `flake.nix`.
2. Add the host to `linuxHosts` in `ad/org.json`.
3. Add an entry to the `vms` map in `variables.tf`.
4. Add a commented `import` block if the VM already exists.
5. Plan, apply, then install with nixos-anywhere from the installer ISO. See "Install a host" in the root `README.md`.

## Memory warning

pve01 has no swap. If the node runs out of memory, the OOM killer stops a guest. Check the committed memory before you add or grow a VM. On 2026-08-25, pve01 had 121 of 125.8 GiB committed. Keep at least 4 GiB of available memory after the VM boots. Count available memory, not free memory. Free memory excludes the reclaimable page cache.
