#!/usr/bin/env bash
# Build the answer ISO for spool, the Tier 0 jump host.
#
# The script renders autounattend.xml and spool-setup.ps1 from the templates
# next to it and writes them into a small ISO. Terraform uploads the ISO and
# attaches it to spool as a second CD-ROM. See terraform/proxmox/README.md.
#
# The script makes a new random local Administrator password at each run.
# The password goes only into the ISO. The script does not print it or keep
# it. The output directory is git-ignored. Do not commit the ISO.
#
# Override a default with an environment variable, for example:
#   GATEWAY=10.100.90.254 ./build-unattend.sh
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMPUTER_NAME="${COMPUTER_NAME:-SPOOL}"
TIME_ZONE="${TIME_ZONE:-Eastern Standard Time}"
IMAGE_NAME="${IMAGE_NAME:-Windows Server 2025 SERVERDATACENTER}"
NIC_NAME="${NIC_NAME:-Ethernet}"
IP_ADDRESS="${IP_ADDRESS:-10.100.90.59}"
PREFIX_LENGTH="${PREFIX_LENGTH:-24}"
GATEWAY="${GATEWAY:-10.100.90.1}"
DNS1="${DNS1:-10.100.90.10}"
DNS2="${DNS2:-10.100.90.11}"
DNS_DOMAIN="${DNS_DOMAIN:-patchwork.internal}"
RDP_ALLOWED="${RDP_ALLOWED:-10.100.79.0/24}"
OUT_DIR="${OUT_DIR:-$here/out}"
ISO_NAME="${ISO_NAME:-autounattend.iso}"

# Find an ISO tool. Use nixpkgs#xorriso when none is on the PATH.
if command -v xorriso >/dev/null 2>&1; then
  mkiso=(xorriso -as mkisofs)
elif command -v mkisofs >/dev/null 2>&1; then
  mkiso=(mkisofs)
else
  mkiso=(nix shell nixpkgs#xorriso -c xorriso -as mkisofs)
fi

# A random password: 24 letters and digits, with at least one upper case
# letter, one lower case letter and one digit (Windows complexity rules).
gen_password() {
  local pw
  while :; do
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
    if [[ ${#pw} -eq 24 && $pw =~ [A-Z] && $pw =~ [a-z] && $pw =~ [0-9] ]]; then
      printf '%s' "$pw"
      return
    fi
  done
}

# The answer file encoding: base64 of UTF-16LE(password + field name).
encode_password() {
  printf '%s%s' "$1" "$2" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n'
}

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

password="$(gen_password)"
admin_b64="$(encode_password "$password" AdministratorPassword)"
autologon_b64="$(encode_password "$password" Password)"
unset password

render() {
  sed \
    -e "s|@@COMPUTER_NAME@@|$COMPUTER_NAME|g" \
    -e "s|@@TIME_ZONE@@|$TIME_ZONE|g" \
    -e "s|@@IMAGE_NAME@@|$IMAGE_NAME|g" \
    -e "s|@@NIC_NAME@@|$NIC_NAME|g" \
    -e "s|@@IP_ADDRESS@@|$IP_ADDRESS|g" \
    -e "s|@@PREFIX_LENGTH@@|$PREFIX_LENGTH|g" \
    -e "s|@@GATEWAY@@|$GATEWAY|g" \
    -e "s|@@DNS1@@|$DNS1|g" \
    -e "s|@@DNS2@@|$DNS2|g" \
    -e "s|@@DNS_DOMAIN@@|$DNS_DOMAIN|g" \
    -e "s|@@RDP_ALLOWED@@|$RDP_ALLOWED|g" \
    -e "s|@@ADMIN_PASSWORD_B64@@|$admin_b64|g" \
    -e "s|@@AUTOLOGON_PASSWORD_B64@@|$autologon_b64|g" \
    "$1"
}

render "$here/autounattend.xml.tmpl" >"$stage/autounattend.xml"
render "$here/spool-setup.ps1.tmpl" >"$stage/spool-setup.ps1"
unset admin_b64 autologon_b64

if grep -q '@@[A-Z0-9_]*@@' "$stage/autounattend.xml" "$stage/spool-setup.ps1"; then
  echo "build-unattend.sh: a placeholder is not rendered" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$ISO_NAME"
"${mkiso[@]}" -quiet -J -r -V SPOOL_UNATTEND -o "$OUT_DIR/$ISO_NAME" "$stage"
chmod 600 "$OUT_DIR/$ISO_NAME"

echo "Wrote $OUT_DIR/$ISO_NAME ($COMPUTER_NAME, $IP_ADDRESS/$PREFIX_LENGTH, gateway $GATEWAY, DNS $DNS1 $DNS2)."
echo "The ISO holds the local Administrator password. Do not commit or share it."
