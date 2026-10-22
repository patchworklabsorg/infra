"""python3 -m unittest discover -s ansible/tests"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "filter_plugins"))
from vyos_secrets import vyos_split_secrets  # noqa: E402

SAMPLE = """\
set interfaces wireguard wg0 address '10.100.92.1/24'
set interfaces wireguard wg0 private-key 'aWdub3JlLW1lLXRlc3Qta2V5LXZhbHVlLTAwMDAwMDA='
set interfaces wireguard wg0 peer laptop public-key 'cHVibGljLWtleS1ub3Qtc2VjcmV0LTAwMDAwMDAwMDA='
set interfaces wireguard wg0 peer laptop preshared-key 'cHNrLXRlc3Q='
set system login radius server 10.100.90.14 key 'radius-test-secret'
set system login user vyos authentication encrypted-password '$6$salt$hash'
set system login user vyos authentication public-keys jsp key 'AAAAC3NzaC1lZDI1NTE5AAAAtest'
set system login user vyos authentication public-keys jsp type 'ssh-ed25519'
set vpn openconnect authentication radius server 10.100.90.14 key 'it'\\''s-a-test'
set system host-name 'thimble'
set service ssh port '22'
set system option motd '{{ not a template }}'
"""


class SplitSecrets(unittest.TestCase):
    def setUp(self):
        self.out = vyos_split_secrets(SAMPLE)
        self.t, self.s = self.out["template"], self.out["secrets"]

    def test_secrets_leave_the_template(self):
        for value in ("aWdub3JlLW1lLXRlc3Qta2V5LXZhbHVlLTAwMDAwMDA=", "cHNrLXRlc3Q=",
                      "radius-test-secret", "$6$salt$hash", "it's-a-test"):
            self.assertIn(value, self.s.values())
            self.assertNotIn(value, self.t)

    def test_public_material_stays(self):
        self.assertIn("public-key 'cHVibGljLWtleS1ub3Qtc2VjcmV0LTAwMDAwMDAwMDA='", self.t)
        self.assertIn("set system host-name 'thimble'", self.t)

    def test_names_are_stable_and_readable(self):
        self.assertIn("interfaces_wireguard_wg0_private_key", self.s)
        self.assertIn("system_login_radius_server_10_100_90_14_key", self.s)

    def test_radius_key_name_for_the_ikev2_vpn(self):
        out = vyos_split_secrets(
            "set vpn ipsec remote-access radius server 10.100.90.14 key 'radius-test'\n")
        self.assertEqual(out["secrets"], {
            "vpn_ipsec_remote_access_radius_server_10_100_90_14_key": "radius-test"})

    def test_acme_chain_ca_is_left_out(self):
        out = vyos_split_secrets(
            "set pki ca AUTOCHAIN_vpn-le certificate 'MIIBfake'\n"
            "set pki ca my-root certificate 'MIIBkept'\n")
        self.assertNotIn("AUTOCHAIN_vpn-le", out["template"])
        self.assertIn("set pki ca my-root certificate 'MIIBkept'", out["template"])

    def test_template_renders_back_to_the_input(self):
        try:
            import jinja2
        except ImportError:
            self.skipTest("jinja2 not installed")
        out = jinja2.Environment(keep_trailing_newline=True).from_string(self.t).render(vyos_secrets=self.s)
        self.assertEqual(out, SAMPLE)


if __name__ == "__main__":
    unittest.main()
