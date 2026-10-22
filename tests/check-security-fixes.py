"""Offline checks of install/security-fixes.sh's trust store, pip, npm,
LiteLLM and file permission steps.

The script's functions are loaded into a fake home. The real openssl checks
bundles against the repo's forged chains; curl is a stub that can't connect,
so nothing touches the network.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
SYSTEM_BUNDLE = Path("/etc/ssl/certs/ca-certificates.crt")
CHAINS = REPO / "install/emudhra-chains"


def certs(path):
    """The PEM certificates in PATH, as strings."""
    blocks, block = [], None
    for line in Path(path).read_text().splitlines(keepends=True):
        if line.startswith("-----BEGIN CERTIFICATE-----"):
            block = []
        if block is not None:
            block.append(line)
        if line.startswith("-----END CERTIFICATE-----") and block is not None:
            blocks.append("".join(block))
            block = None
    return blocks


@unittest.skipUnless(SYSTEM_BUNDLE.exists() and shutil.which("openssl"), "needs openssl and a system bundle")
class SecurityFixesChecks(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="configs-security-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "curl").write_text("#!/bin/sh\nexit 7\n")
        (self.bin / "curl").chmod(0o755)
        script = (REPO / "install/security-fixes.sh").read_text()
        self.functions = self.root / "functions.sh"
        self.functions.write_text(script.rsplit("\ntrust_store\n", 1)[0] + "\n")
        self.env = {"HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin", "LANG": "C",
                    "XDG_DATA_HOME": str(self.home / ".local/share")}
        self.bundle = self.home / ".local/share/configs/ca-bundle.pem"

    def run_steps(self, steps, ok=True, **env):
        # Use the stub curl and the repo's chains, whatever the real paths hold.
        body = (f'set --; . "{self.functions}"\n'
                f'pick() {{ case $1 in curl) echo "{self.bin}/curl" ;; *) command -v "$1" ;; esac; }}\n'
                f'CHAINS="{CHAINS}"\n{steps}\n'
                '[ -z "$failed" ] || { echo "failed:$failed" >&2; exit 1; }\n')
        result = subprocess.run(["bash", "-c", body], env={**self.env, **env}, text=True,
                                capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def write_bundle(self, name, blocks):
        path = self.root / name
        path.write_text("".join(blocks))
        return path

    def forged_chain(self, name="dv-g3b-emudhra"):
        return certs(CHAINS / f"{name}.we-have-a-problem.com.pem")

    def test_clean_system_bundle_is_linked(self):
        out = self.run_steps("trust_store", SYSTEM_CA_BUNDLE=str(SYSTEM_BUNDLE))
        self.assertTrue(self.bundle.is_symlink(), out)
        self.assertEqual(os.readlink(self.bundle), str(SYSTEM_BUNDLE))
        self.assertIn("only the offline check ran", out)
        self.assertIn('capath = "', (self.bundle.parent / "curl/.curlrc").read_text())

    def test_bad_root_and_compromised_intermediate_are_removed(self):
        # The emSign root from a forged chain, and a compromised intermediate
        # trusted directly, both added to the clean store.
        chain = self.forged_chain()
        dirty = self.write_bundle("dirty.pem", certs(SYSTEM_BUNDLE) + chain[1:])
        out = self.run_steps("trust_store", SYSTEM_CA_BUNDLE=str(dirty))
        self.assertFalse(self.bundle.is_symlink(), out)
        self.assertEqual(len(certs(self.bundle)), len(certs(SYSTEM_BUNDLE)), out)
        self.assertIn("(2 certificates)", out)

    def test_store_trusting_a_compromised_intermediate_fails(self):
        # Only the intermediate, not a self-signed root, as the anchor.
        bad = self.write_bundle("bad.pem", certs(SYSTEM_BUNDLE) + self.forged_chain()[1:2])
        out = self.run_steps(f'openssl=$(command -v openssl); check_chains "{bad}" || failed=chains',
                             ok=False)
        self.assertIn("dv-g3b-emudhra: accepted", out)
        self.assertIn("dv-g3b-noct-emudhra: accepted", out)

    def test_clean_store_passes_the_chain_check(self):
        self.run_steps(f'openssl=$(command -v openssl); check_chains "{SYSTEM_BUNDLE}" || failed=chains')

    def test_unreadable_certificate_fails_without_a_bundle(self):
        corrupt = self.write_bundle("corrupt.pem", certs(SYSTEM_BUNDLE) +
                                    ["-----BEGIN CERTIFICATE-----\nnotbase64\n-----END CERTIFICATE-----\n"])
        out = self.run_steps("trust_store", ok=False, SYSTEM_CA_BUNDLE=str(corrupt))
        self.assertFalse(self.bundle.exists(), out)

    def test_pip_trusted_host_is_removed_with_a_backup(self):
        conf = self.home / ".config/pip/pip.conf"
        conf.parent.mkdir(parents=True)
        conf.write_text("[global]\nindex-url = https://pypi.org/simple\nextra-index-url =\n"
                        "                  https://pypi.example.org\ntrusted-host =\n"
                        "               pypi.example.org\nno-cache-dir = true\n")
        before = conf.read_text()
        out = self.run_steps("pip_config")
        self.assertNotIn("trusted-host", conf.read_text(), out)
        self.assertIn("https://pypi.example.org", conf.read_text())
        self.assertIn("no-cache-dir = true", conf.read_text())
        backups = list((self.home / ".local/state/configs/config-backups/security-fixes").iterdir())
        self.assertEqual([b.read_text() for b in backups], [before])
        self.assertEqual(self.run_steps("pip_config"), "")

    def test_npm_gets_the_bundle_once(self):
        self.run_steps("trust_store", SYSTEM_CA_BUNDLE=str(SYSTEM_BUNDLE))
        npm = self.home / ".nvm/versions/node/v24.22.1/bin/npm"
        npm.parent.mkdir(parents=True)
        npm.write_text("")
        self.run_steps("npm_config")
        self.run_steps("npm_config")
        self.assertEqual((self.home / ".npmrc").read_text(), f"cafile={self.bundle}\n")

    def test_existing_npm_cafile_is_kept(self):
        self.run_steps("trust_store", SYSTEM_CA_BUNDLE=str(SYSTEM_BUNDLE))
        (self.home / ".npmrc").write_text("cafile=/corp/ca.pem\n")
        self.run_steps("npm_config")
        self.assertEqual((self.home / ".npmrc").read_text(), "cafile=/corp/ca.pem\n")

    def test_litellm_payload_fails(self):
        site = self.home / "projects/app/.venv/lib/python3.12/site-packages"
        site.mkdir(parents=True)
        (site / "sitecustomize.py").write_text("# an ordinary one\n")
        out = self.run_steps("litellm")
        self.assertIn("No traces found", out)
        (site / "cook.pth").write_text("import cook\n")
        out = self.run_steps("litellm", ok=False)
        self.assertIn("cook.pth", out)
        self.assertNotIn("sitecustomize.py", out)

    def test_private_files_lose_group_and_other_access(self):
        ssh = self.home / ".ssh"
        ssh.mkdir(mode=0o755)
        (ssh / "id_ed25519").write_text("")
        (ssh / "id_ed25519").chmod(0o644)
        self.run_steps("private_files")
        self.assertEqual(ssh.stat().st_mode & 0o777, 0o700)
        self.assertEqual((ssh / "id_ed25519").stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
