"""Checks vyos.yml and the VyOS templates for the 512-column read problem."""
import glob
import os
import re
import unittest

HERE = os.path.dirname(__file__)
PLAYBOOK = os.path.join(HERE, "..", "vyos.yml")
TEMPLATES = glob.glob(os.path.join(HERE, "..", "templates", "vyos", "*.conf.j2"))

try:
    import yaml
except ImportError:  # the nix check has pyyaml; a bare python3 may not
    if os.environ.get("NIX_BUILD_TOP"):
        raise
    yaml = None


def _tasks():
    with open(PLAYBOOK) as fh:
        return [t for play in yaml.safe_load(fh) for t in play["tasks"]]


@unittest.skipIf(yaml is None, "pyyaml not installed")
class ConfigReads(unittest.TestCase):
    def test_full_config_reads_use_a_pipe(self):
        # Without a pipe, VyOS puts a space in place of every 512th character.
        bare = re.compile(r"^show\s+conf\w*\s+commands\s*$")
        for task in _tasks():
            cmds = task.get("vyos.vyos.vyos_command", {}).get("commands", [])
            for cmd in cmds if isinstance(cmds, list) else [cmds]:
                if bare.match(str(cmd).strip()):
                    self.fail(f"{task['name']}: read with '| cat'")

    def test_apply_diffs_against_the_piped_read(self):
        apply = next(t for t in _tasks() if "vyos.vyos.vyos_config" in t)
        self.assertIn("vyos_running_apply", apply["vyos.vyos.vyos_config"].get("config", ""))
        read = next(t for t in _tasks() if t.get("register") == "vyos_running_apply")
        self.assertTrue(read["vyos.vyos.vyos_command"]["commands"].endswith("| cat"))
        self.assertIs(read.get("check_mode"), False)


class TemplateCertificates(unittest.TestCase):
    def test_certificates_have_no_spaces(self):
        # A pull without the pipe wrote a space into a long base64 value.
        line_re = re.compile(r"^set pki \S+ \S+ certificate '([^']*)'")
        for path in TEMPLATES:
            with open(path) as fh:
                for n, line in enumerate(fh, 1):
                    m = line_re.match(line)
                    if m:
                        self.assertNotIn(" ", m.group(1), f"{os.path.basename(path)}:{n}")


if __name__ == "__main__":
    unittest.main()
