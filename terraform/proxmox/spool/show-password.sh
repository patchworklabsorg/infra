#!/usr/bin/env bash
# Read the local Administrator password of spool back from the answer ISO.
# You need it once, for the manual domain join. After the join, LAPS sets a
# new password, and this one is no longer valid.
#
#   show-password.sh [ISO]          print the password
#   show-password.sh --copy [ISO]   copy it to the macOS clipboard (pbcopy)
#
# The default ISO is spool/out/autounattend.iso.
set -euo pipefail

copy=false
if [[ "${1:-}" == "--copy" ]]; then
  copy=true
  shift
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
iso="${1:-$here/out/autounattend.iso}"
[[ -f "$iso" ]] || { echo "show-password.sh: $iso not found" >&2; exit 1; }

if command -v xorriso >/dev/null 2>&1; then
  xorriso=(xorriso)
else
  xorriso=(nix shell nixpkgs#xorriso -c xorriso)
fi

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"${xorriso[@]}" -osirrox on -indev "$iso" -extract /autounattend.xml "$tmp/autounattend.xml" >/dev/null 2>&1

# The first encoded <Value> is AdministratorPassword:
# base64(UTF-16LE(password + "AdministratorPassword")).
encoded="$(grep -A1 '<AdministratorPassword>' "$tmp/autounattend.xml" |
  sed -n 's|.*<Value>\(.*\)</Value>.*|\1|p' | head -n 1)"
decoded="$(printf '%s' "$encoded" | base64 -d | iconv -f UTF-16LE -t UTF-8)"
password="${decoded%AdministratorPassword}"

if $copy; then
  printf '%s' "$password" | pbcopy
  echo "Copied the spool local Administrator password to the clipboard."
else
  printf '%s\n' "$password"
fi
