"""Copy the Patchwork values from the personal vault. See bin/vault-import.

Reads the personal vault (jaspermayone/infra) with its own password file,
and writes:
  - vault/vault.yml (the infra-vault submodule), encrypted with
    ~/.vault-pass-patchwork. The password file is created (random, 0600) if
    it does not exist. Existing keys are kept unless --force.
  - ../secrets/ad-join.age (agenix), for the join password, encrypted to the
    recipients in secrets/secrets.nix. Kept if it exists, unless --force.

It prints key names and file names only, never a value.
"""
import argparse
import json
import os
import secrets
import subprocess
import sys
import tempfile

import yaml
from ansible.parsing.vault import VaultLib, VaultSecret

ANSIBLE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(ANSIBLE)

# personal vault key -> Patchwork vault key
KEYS = {
    "vault_ad_svc_ansible_password_patchwork": "vault_ad_svc_ansible_password",
    "vault_wazuh_ldap_bind_password_patchwork": "vault_wazuh_ldap_bind_password",
    "vault_netbox_ldap_bind_password_patchwork": "vault_netbox_ldap_bind_password",
}
# personal vault key -> agenix file in ../secrets
AGE = {
    "vault_ad_join_password_patchwork": "ad-join.age",
}
NIX = ["nix", "--extra-experimental-features", "nix-command flakes"]


def vault_for(path):
    with open(os.path.expanduser(path), "rb") as fh:
        return VaultLib([("default", VaultSecret(fh.read().strip()))])


def read_vault(path, vault):
    with open(path, "rb") as fh:
        blob = fh.read()
    if not vault.is_encrypted(blob):
        sys.exit(f"vault-import: {path} is not a whole-file vault")
    return yaml.safe_load(vault.decrypt(blob)) or {}


def write_age(secrets_dir, name, value, force, dry_run):
    out = os.path.join(secrets_dir, name)
    if os.path.exists(out) and not force:
        print(f"kept      secrets/{name} (exists; --force to replace)")
        return
    if dry_run:
        print(f"would set secrets/{name}")
        return
    recipients = json.loads(subprocess.run(
        NIX + ["eval", "--json", "--file", os.path.join(secrets_dir, "secrets.nix"),
               "--apply", f'x: x."{name}".publicKeys'],
        check=True, capture_output=True, text=True).stdout)
    with tempfile.NamedTemporaryFile("w", suffix=".pub", delete=False) as fh:
        fh.write("\n".join(recipients) + "\n")
        rfile = fh.name
    try:
        subprocess.run(NIX + ["shell", "nixpkgs#age", "-c", "age", "--encrypt",
                              "--recipients-file", rfile, "--output", out],
                       input=value.encode(), check=True)
    finally:
        os.unlink(rfile)
    print(f"set       secrets/{name} for {len(recipients)} recipients")


def main():
    ap = argparse.ArgumentParser(prog="vault-import")
    ap.add_argument("--from", dest="src",
                    default=os.path.expanduser("~/dev/infra/ansible/inventory/group_vars/all/vault.yml"))
    ap.add_argument("--from-password-file", default="~/.vault-pass")
    ap.add_argument("--to", default=os.path.join(ANSIBLE, "vault/vault.yml"))
    ap.add_argument("--to-password-file", default="~/.vault-pass-patchwork")
    ap.add_argument("--secrets-dir", default=os.path.join(REPO, "secrets"))
    ap.add_argument("--force", action="store_true", help="replace keys and files that exist")
    ap.add_argument("--dry-run", action="store_true", help="print what would change, write nothing")
    a = ap.parse_args()

    src = read_vault(a.src, vault_for(a.from_password_file))

    to_pass = os.path.expanduser(a.to_password_file)
    if not os.path.exists(to_pass):
        if a.dry_run:
            print(f"would create {a.to_password_file} (random)")
        else:
            fd = os.open(to_pass, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as fh:
                fh.write(secrets.token_urlsafe(32) + "\n")
            print(f"created   {a.to_password_file} (random, 0600). Keep a copy in your password manager.")

    dst_path = os.path.realpath(a.to)
    dst = {}
    if os.path.exists(dst_path) and os.path.exists(to_pass):
        dst = read_vault(dst_path, vault_for(to_pass))

    changed = False
    for old, new in KEYS.items():
        if old not in src or src[old] in (None, ""):
            print(f"missing   {old} (not in the personal vault; skipped)")
        elif new in dst and not a.force:
            print(f"kept      {new} (exists; --force to replace)")
        else:
            print(f"{'would set' if a.dry_run else 'set      '} {new} <- {old}")
            dst[new] = src[old]
            changed = True

    for old, name in AGE.items():
        if old not in src or src[old] in (None, ""):
            print(f"missing   {old} (not in the personal vault; skipped)")
        else:
            write_age(a.secrets_dir, name, str(src[old]), a.force, a.dry_run)

    if changed and not a.dry_run:
        enc = vault_for(to_pass).encrypt(yaml.safe_dump(dst, default_flow_style=False, sort_keys=True).encode())
        tmp = dst_path + ".tmp"
        with open(tmp, "wb") as fh:
            fh.write(enc)
        os.chmod(tmp, 0o600)
        os.replace(tmp, dst_path)
        print(f"wrote     {os.path.relpath(dst_path, ANSIBLE)}")

    print("Not copied on purpose: the _patchwork NetBox, Diode, Orb and Wazuh agent keys "
          "(no Patchwork host uses them), and the Tailscale key (roll a new one).")


if __name__ == "__main__":
    main()
