"""vyos_split_secrets: turn `show configuration commands` into a repo-safe template.

Input: the text of `show configuration commands` from a VyOS router.
Output: {"template": str, "secrets": {name: value}}.

Each `set` line whose value is a secret (a private key, a pre-shared key, a
RADIUS or other shared secret, a password or password hash) becomes
    set <path> '{{ vyos_secrets["<name>"] | replace(...) }}'
and the value goes in `secrets`, which vyos.yml -t pull writes to the vault.
Lines that VyOS derives itself (DERIVED) are left out. Every other line is
copied, with any "{{", "{%" or "{#" escaped so that Jinja renders it
unchanged. The template then renders back to the same commands.

No Ansible import, so tests/test_vyos_secrets.py runs with plain Python.
"""
import re

# The last path word before the value. These are the VyOS options that hold
# secret material. "key" alone covers RADIUS/TACACS server keys and
# "pki ... private key".
SECRET_WORDS = {
    "private-key",
    "preshared-key",
    "pre-shared-secret",
    "shared-secret",
    "shared-secret-key",
    "secret",
    "key",
    "password",
    "plaintext-password",
    "encrypted-password",
    "authentication-key",
    "md5-key",
    "psk",
}

# Lines that pull leaves out. VyOS writes them itself, so they are not
# configuration: pki adds "pki ca AUTOCHAIN_<cert>" with the issuer of each
# ACME certificate (vpn-le), and replaces it when Let's Encrypt changes the
# intermediate. A copy in the template would set the old issuer back.
DERIVED = re.compile(r"^set pki ca AUTOCHAIN_\S+ ")

LINE = re.compile(r"^set (?P<path>.+?) (?P<word>[\w-]+) (?P<value>'(?:[^']|'\\'')*'|\S+)$")
JINJA_OPEN = re.compile(r"\{([{%#])")


def _unquote(value):
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1].replace("'\\''", "'")
    return value


def _name(path, word, used):
    base = re.sub(r"[^a-z0-9]+", "_", f"{path} {word}".lower()).strip("_")
    name, n = base, 2
    while name in used:
        name, n = f"{base}_{n}", n + 1
    return name


def vyos_split_secrets(text):
    lines, found = [], {}
    for raw in text.splitlines():
        line = raw.rstrip()
        if DERIVED.match(line):
            continue
        m = LINE.match(line)
        # "public-key" and the like do not match: the word must be exact.
        if m and m.group("word") in SECRET_WORDS:
            name = _name(m.group("path"), m.group("word"), found)
            found[name] = _unquote(m.group("value"))
            path = JINJA_OPEN.sub(lambda x: "{{ '{" + x.group(1) + "' }}", m.group("path"))
            # The value is stored unquoted; the template quotes it the way
            # VyOS prints it (a ' becomes '\'').
            lines.append(
                f"set {path} {m.group('word')} "
                f"'{{{{ vyos_secrets[\"{name}\"] | replace(\"'\", \"'\\\\''\") }}}}'"
            )
        else:
            lines.append(JINJA_OPEN.sub(lambda x: "{{ '{" + x.group(1) + "' }}", line))
    return {"template": "\n".join(lines) + "\n", "secrets": found}


class FilterModule:
    def filters(self):
        return {"vyos_split_secrets": vyos_split_secrets}
