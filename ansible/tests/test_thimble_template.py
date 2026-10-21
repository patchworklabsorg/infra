"""Renders templates/vyos/thimble.conf.j2 at each IKEv2 stage (README.md, "VPN")."""
import os
import re
import sys
import unittest

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "filter_plugins"))
from vyos_secrets import vyos_split_secrets  # noqa: E402

TEMPLATE = os.path.join(HERE, "..", "templates", "vyos", "thimble.conf.j2")
RADIUS_KEY = "vpn_ipsec_remote_access_radius_server_10_100_90_14_key"
PW_NETS = ["10.100.90.0/24", "10.100.91.0/24", "10.100.92.0/24"]

try:
    import jinja2
except ImportError:  # the nix check has jinja2; a bare python3 may not
    jinja2 = None


class _Secrets(dict):
    """Gives a fake value for each secret name and records the names."""

    def __missing__(self, name):
        return f"fake-{name}"


@unittest.skipIf(jinja2 is None, "jinja2 not installed")
class ThimbleStages(unittest.TestCase):
    def render(self, stage):
        # Ansible renders templates with trim_blocks on.
        env = jinja2.Environment(trim_blocks=True, keep_trailing_newline=True,
                                 undefined=jinja2.StrictUndefined)
        with open(TEMPLATE) as fh:
            text = env.from_string(fh.read()).render(
                vyos_secrets=_Secrets(), vyos_ikev2_stage=stage)
        return [line for line in text.splitlines() if line.strip()]

    def test_every_line_is_a_command(self):
        for stage in range(6):
            for line in self.render(stage):
                self.assertRegex(line, r"^(set|delete) ", f"stage {stage}: {line}")

    def test_stage_0_adds_nothing(self):
        for line in self.render(0):
            self.assertFalse(line.startswith(("set firewall", "set pki", "set vpn")), line)
            self.assertNotIn("10.100.93.", line)

    def test_stages_only_add(self):
        # Each stage keeps the lines of the stage before it, except the
        # values that the stage changes on purpose.
        changed = ("set firewall ipv4 input filter default-action",
                   "set firewall ipv4 input filter rule 999",
                   "set pki certificate vpn-le acme url")
        for stage in range(1, 6):
            before = {line for line in self.render(stage - 1) if not line.startswith(changed)}
            self.assertLessEqual(before, set(self.render(stage)), f"stage {stage}")

    def test_input_drops_only_at_stage_5(self):
        for stage in range(1, 5):
            lines = self.render(stage)
            self.assertIn("set firewall ipv4 input filter default-action 'accept'", lines)
            self.assertIn("set firewall ipv4 input filter rule 999 action 'accept'", lines)
        lines = self.render(5)
        self.assertIn("set firewall ipv4 input filter default-action 'drop'", lines)
        self.assertIn("delete firewall ipv4 input filter rule 999", lines)

    def test_input_keeps_ssh_wireguard_and_ike(self):
        text = "\n".join(self.render(1))
        for want in ("destination port '22'", "destination port '51822'",
                     "destination port '500,4500'", "destination port '80'",
                     "state 'established'", "inbound-interface name 'lo'"):
            self.assertIn(want, text)
        for net in ("10.100.79.0/24", "10.100.90.0/24", "10.100.93.0/24"):
            self.assertIn(f"set firewall group network-group SSH-SOURCES network '{net}'", text)

    def test_acme_staging_then_production(self):
        staging = "url 'https://acme-staging-v02.api.letsencrypt.org/directory'"
        production = "url 'https://acme-v02.api.letsencrypt.org/directory'"
        self.assertFalse(any("acme" in line for line in self.render(1)))
        self.assertTrue(any(line.endswith(staging) for line in self.render(2)))
        for stage in (3, 4, 5):
            self.assertTrue(any(line.endswith(production) for line in self.render(stage)))
            self.assertFalse(any(line.endswith(staging) for line in self.render(stage)))

    def test_split_tunnel_selectors(self):
        lines = self.render(4)
        prefixes = [re.search(r"'(.+)'", line).group(1) for line in lines
                    if line.startswith("set vpn ipsec remote-access connection pw-ikev2 local prefix")]
        self.assertEqual(sorted(prefixes), PW_NETS)
        self.assertFalse(any("10.100.0.0/16" in line for line in lines))

    def test_connection_name_is_valid(self):
        names = {line.split()[5] for line in self.render(4)
                 if line.startswith("set vpn ipsec remote-access connection ")}
        self.assertEqual(names, {"pw-ikev2"})
        # The constraint in vyos-1x interface-definitions/vpn_ipsec.xml.in.
        self.assertTrue(all(re.fullmatch(r"[a-zA-Z][0-9a-zA-Z_-]+", n) for n in names))

    def test_radius_key_name_matches_pull(self):
        # pull (vyos_split_secrets) must give the router's line the same name
        # that the template reads, or the next pull makes a second key.
        lines = [line for line in self.render(4) if " radius server " in line and " key " in line]
        self.assertEqual(len(lines), 1)
        out = vyos_split_secrets(lines[0] + "\n")
        self.assertEqual(list(out["secrets"]), [RADIUS_KEY])
        self.assertEqual(out["secrets"][RADIUS_KEY], f"fake-{RADIUS_KEY}")


if __name__ == "__main__":
    unittest.main()
