#!/usr/bin/env bash
# Patchwork Labs Google Workspace setup (GAM7)
# Usage:
#   ./patchwork-workspace-setup.sh domains     add secondary domains, print verification records
#   ./patchwork-workspace-setup.sh verify      verify domains after DNS records are in
#   ./patchwork-workspace-setup.sh structure   OUs, groups, memberships, user attributes
#
# Required env vars for "structure":
#   KIERAN, DOMINIC, ADAM  (their patchworklabs.org addresses)
#
# Not using set -e on purpose: GAM exits nonzero on "already exists",
# and reruns should just skip what's there.
set -u

GAM="${GAM_BIN:-$HOME/bin/gam7/gam} select patchwork"
DOMAIN="patchworklabs.org"
JASPER="jasper@${DOMAIN}"
SECONDARY=(hackboston.dev hackathon.help)

phase_domains() {
  for d in "${SECONDARY[@]}"
  do
    $GAM create domain "$d"
    $GAM create verify "$d"
  done
  echo
  echo "Add the TXT records above at your DNS provider, wait a few minutes, then run: $0 verify"
}

phase_verify() {
  for d in "${SECONDARY[@]}"
  do
    $GAM update verify "$d" txt
  done
  $GAM print domains
}

phase_structure() {
  : "${KIERAN:?set KIERAN}" "${DOMINIC:?set DOMINIC}" "${ADAM:?set ADAM}"

  # ---------- OUs ----------
  for ou in "/Staff" "/Board-Only" "/Service-Accounts" "/Purgatory" \
            "/Sponsored-Projects" "/Sponsored-Projects/HackBoston" "/Sponsored-Projects/hackathon.help"
  do
    $GAM create org "$ou"
  done
  $GAM update org "/Staff"              description "Patchwork staff and volunteers with operational roles"
  $GAM update org "/Board-Only"         description "Directors with no operational role"
  $GAM update org "/Service-Accounts"   description "Non-human accounts for integrations"
  $GAM update org "/Purgatory"          description "Suspended users, all services off"
  $GAM update org "/Sponsored-Projects" description "Fiscally sponsored projects"

  # ---------- Governance groups ----------
  $GAM create group "board@${DOMAIN}"     name "Board of Directors"
  $GAM create group "president@${DOMAIN}" name "President"
  $GAM create group "treasurer@${DOMAIN}" name "Treasurer"
  $GAM create group "secretary@${DOMAIN}" name "Secretary"

  for u in "$JASPER" "$KIERAN" "$DOMINIC"
  do
    $GAM update group "board@${DOMAIN}" add member "$u"
  done
  $GAM update group "president@${DOMAIN}" add member "$JASPER"
  $GAM update group "treasurer@${DOMAIN}" add member "$KIERAN"
  $GAM update group "secretary@${DOMAIN}" add member "$KIERAN"

  # ---------- Program groups ----------
  $GAM create group "ganymede-admins@${DOMAIN}" name "Ganymede Admins"
  $GAM create group "ganymede-users@${DOMAIN}"  name "Ganymede Users"
  $GAM update group "ganymede-users@${DOMAIN}" allowexternalmembers true
  $GAM update group "ganymede-admins@${DOMAIN}" add member "$JASPER"
  $GAM update group "ganymede-admins@${DOMAIN}" add member "$ADAM"

  # ---------- Sponsored project groups (domains must be verified first) ----------
  $GAM create group "organizers@hackboston.dev" name "HackBoston Organizers"
  $GAM create group "organizers@hackathon.help" name "hackathon.help Organizers"
  $GAM update group "organizers@hackboston.dev" add member "$JASPER"

  # ---------- Ops groups (GCP IAM targets) ----------
  $GAM create group "gcp-admins@${DOMAIN}" name "GCP Admins"
  $GAM create group "infra@${DOMAIN}"      name "Infrastructure"
  $GAM update group "gcp-admins@${DOMAIN}" add member "$JASPER"
  $GAM update group "infra@${DOMAIN}"      add member "$JASPER"

  # ---------- User placement and attributes ----------
  $GAM update user "$JASPER" ou "/Staff" \
    organization type work name "Patchwork Labs inc." title "Founder & Director of Programs" \
    department "Project Ganymede" costcenter "Programs" primary

  $GAM update user "$ADAM" ou "/Staff" \
    organization type work name "Patchwork Labs inc." title "Project Ganymede Administrator" \
    department "Project Ganymede" costcenter "Programs" primary

  for u in "$KIERAN" "$DOMINIC"
  do
    $GAM update user "$u" ou "/Board-Only" \
      organization type work name "Patchwork Labs inc." \
      department "Governance" costcenter "Operations" primary
  done

  # ---------- Check ----------
  $GAM print orgs allfields
  $GAM print groups members
  $GAM info user "$JASPER" organizations
}

case "${1:-}" in
  domains)   phase_domains ;;
  verify)    phase_verify ;;
  structure) phase_structure ;;
  *) echo "usage: $0 domains|verify|structure" ; exit 1 ;;
esac
