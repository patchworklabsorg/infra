#!/usr/bin/env bash
# Attach or detach the spool answer ISO as a second CD-ROM, through the
# Proxmox API. terraform_data.spool_unattend_cdrom in windows.tf runs it.
#
# Why a script: bpg/proxmox 0.116 allows only one cdrom block on
# proxmox_virtual_environment_vm (issue bpg/terraform-provider-proxmox#718),
# and that block holds the Windows ISO.
#
#   attach-unattend.sh attach   set ide0 to the answer ISO, then start the
#                               VM and press Enter for the "boot from CD"
#                               prompt, if the VM is stopped
#   attach-unattend.sh detach   remove ide0
#
# Input (environment):
#   PVE_ENDPOINT  Proxmox URL, for example https://proxmox.example/
#   PVE_NODE      node name
#   PVE_VMID      VM ID
#   PVE_ISO       volume ID of the answer ISO (attach only)
#   PVE_IFACE     CD-ROM interface (default ide0)
#   PROXMOX_VE_API_TOKEN  the same token as the provider. Never printed.
#   PROXMOX_VE_INSECURE   "true" to accept a self-signed certificate
set -euo pipefail

action="${1:?usage: attach-unattend.sh attach|detach}"
: "${PVE_ENDPOINT:?}" "${PVE_NODE:?}" "${PVE_VMID:?}"
: "${PROXMOX_VE_API_TOKEN:?PROXMOX_VE_API_TOKEN is not set}"
iface="${PVE_IFACE:-ide0}"
base="${PVE_ENDPOINT%/}/api2/json/nodes/$PVE_NODE/qemu/$PVE_VMID"

curl_opts=(-sS -f)
if [[ "${PROXMOX_VE_INSECURE:-false}" == "true" ]]; then
  curl_opts+=(-k)
fi

# The token goes to curl on stdin, not on the command line.
api() {
  local method="$1" path="$2"
  shift 2
  printf 'header = "Authorization: PVEAPIToken=%s"\n' "$PROXMOX_VE_API_TOKEN" |
    curl "${curl_opts[@]}" -K - -X "$method" "$base$path" "$@"
}

vm_status() {
  api GET /status/current | grep -o '"status":"[a-z]*"' | head -n 1 | cut -d '"' -f 4
}

case "$action" in
  attach)
    : "${PVE_ISO:?}"
    api PUT /config --data-urlencode "$iface=$PVE_ISO,media=cdrom" >/dev/null
    echo "spool: $iface is $PVE_ISO."

    status="$(vm_status)"
    if [[ "$status" != "stopped" ]]; then
      echo "spool: the VM is $status. It is not started again."
      exit 0
    fi

    api POST /status/start >/dev/null
    echo "spool: started. Pressing Enter for the boot from CD prompt."
    # OVMF tries the empty sata0 first, then the Windows ISO on ide2, which
    # waits about 5 seconds for a key. Send Enter for 30 seconds.
    # sendkey needs VM.Console. Without it, press a key in the console.
    for _ in $(seq 1 30); do
      sleep 1
      if ! api PUT /sendkey --data key=ret >/dev/null 2>&1; then
        echo "spool: sendkey failed. Press a key in the Proxmox console of VM $PVE_VMID now."
        break
      fi
    done
    ;;
  detach)
    if api PUT /config --data-urlencode "delete=$iface" >/dev/null; then
      echo "spool: $iface removed."
    else
      echo "spool: could not remove $iface. Remove it in the Proxmox UI." >&2
    fi
    ;;
  *)
    echo "usage: attach-unattend.sh attach|detach" >&2
    exit 2
    ;;
esac
