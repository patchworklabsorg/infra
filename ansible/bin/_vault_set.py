"""Set one key in a whole-file Ansible vault. Value comes from stdin. See bin/vault-set."""
import argparse
import json
import os
import re
import sys

from ansible.parsing.vault import VaultLib, VaultSecret

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser(prog="vault-set")
    ap.add_argument("key")
    ap.add_argument("--json", metavar="FIELD", help="stdin holds JSON; take this field")
    ap.add_argument("--file", default=os.path.join(REPO, "vault/vault.yml"))
    ap.add_argument("--password-file", default=os.path.expanduser("~/.vault-pass-patchwork"))
    ap.add_argument("--no-clobber", action="store_true", help="leave an existing key untouched")
    a = ap.parse_args()

    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", a.key):
        sys.exit(f"vault-set: bad key name {a.key!r}")

    raw = sys.stdin.read()
    if a.json:
        m = re.search(r"\{.*\}", raw, re.S)
        if not m:
            sys.exit("vault-set: no JSON object on stdin")
        value = json.loads(m.group(0))
        for part in a.json.split("."):
            value = value[part]
    else:
        value = raw.rstrip("\n")
    if not isinstance(value, str) or not value:
        sys.exit("vault-set: empty value, nothing written")

    with open(a.password_file, "rb") as fh:
        secret = VaultSecret(fh.read().strip())
    vault = VaultLib([("default", secret)])
    # Write to the real file. A symlink (inventory/group_vars/all/vault.yml)
    # would be replaced by a plain file at os.replace() below.
    a.file = os.path.realpath(a.file)
    with open(a.file, "rb") as fh:
        blob = fh.read()
    if not vault.is_encrypted(blob):
        sys.exit(f"vault-set: {a.file} is not a whole-file vault")
    plain = vault.decrypt(blob).decode()

    line = f"{a.key}: {json.dumps(value)}"
    pat = re.compile(rf"^{re.escape(a.key)}:.*$", re.M)
    if pat.search(plain):
        if a.no_clobber:
            print(f"vault-set: {a.key} already set, left as is (--no-clobber)")
            return
        plain, n = pat.subn(line, plain, count=1)
        action = "replaced"
    else:
        if not plain.endswith("\n"):
            plain += "\n"
        plain += line + "\n"
        action = "added"

    enc = vault.encrypt(plain.encode())
    mode = os.stat(a.file).st_mode & 0o777
    tmp = a.file + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(enc)
    os.chmod(tmp, mode)
    os.replace(tmp, a.file)
    print(f"vault-set: {a.key} {action} in {os.path.relpath(a.file, REPO)}")


if __name__ == "__main__":
    main()
