"""Offline checks of the Tailscale section of install/security-fixes.sh.

Only the script's functions are loaded, with a PATH of stubs, so nothing
touches the real trust store, files, network or Tailscale.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent

TAILSCALE = r'''#!/bin/bash
echo "tailscale $*" >> "$STATE/calls"
case "$*" in
  version) [ -s "$STATE/client" ] || exit 1
    cat "$STATE/client"; echo "  go version: go1.27.3" ;;
  "version --daemon") [ -s "$STATE/daemon" ] || { echo "failed to connect to local tailscaled" >&2; exit 1; }
    echo "Client: $(cat "$STATE/client")"; echo "Daemon: $(cat "$STATE/daemon")" ;;
  "update --yes") [ -e "$STATE/update-fails" ] && exit 1
    cp "$STATE/new-client" "$STATE/client"
    if [ -e "$STATE/new-daemon" ]; then cp "$STATE/new-daemon" "$STATE/daemon"; fi ;;
  *) exit 2 ;;
esac
'''

SUDO = r'''#!/bin/bash
echo "sudo $*" >> "$STATE/calls"
[ "$1" = -n ] && [ -e "$STATE/sudo-ok" ] || exit 1
shift
[ "$*" = true ] || exec "$@"
'''

BREW = r'''#!/bin/bash
echo "brew $*" >> "$STATE/calls"
case "$1" in
  --prefix) echo "$BREW_PREFIX" ;;
  update) ;;
  upgrade) cp "$STATE/new-client" "$STATE/client" ;;
esac
'''


class TailscaleChecks(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="configs-tailscale-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        # Only these real commands, so a real tailscale, sudo or brew is never found.
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("sed", "awk", "cat", "cp", "rm", "mktemp"):
            os.symlink(shutil.which(name), self.bin / name)
        self.stub("id", 'echo 1000\n')
        self.stub("uname", 'echo Linux\n')
        self.stub("sleep", 'exit 0\n')
        self.env = {"PATH": str(self.bin), "HOME": str(self.root), "STATE": str(self.state), "LANG": "C"}
        # The script's functions and settings, without the calls at the end.
        script = (REPO / "install/security-fixes.sh").read_text()
        # Keep the absolute Mac-app fallback inside the fixture as well.
        self.mac_app = self.root / "Tailscale"
        script = script.replace("/Applications/Tailscale.app/Contents/MacOS/Tailscale", str(self.mac_app))
        self.functions = self.root / "functions.sh"
        self.functions.write_text(script.rsplit("\nmain\n", 1)[0] + "\n")

    def stub(self, name, body, directory=None):
        path = (directory or self.bin) / name
        path.write_text(body if body.startswith("#!") else "#!/bin/bash\n" + body)
        path.chmod(0o755)
        return path

    def install(self, client, daemon=None, new_client=None, new_daemon=None):
        self.stub("tailscale", TAILSCALE)
        (self.state / "client").write_text(client + "\n")
        if daemon:
            (self.state / "daemon").write_text(daemon + "\n")
        if new_client:
            (self.state / "new-client").write_text(new_client + "\n")
        if new_daemon:
            (self.state / "new-daemon").write_text(new_daemon + "\n")

    def run_check(self, failed=""):
        result = subprocess.run(
            ["/bin/bash", "-c", 'f=$1 was=$2; shift 2; . "$f"; failed=$was; tailscale_update; echo "failed=[$failed]"',
             "check", str(self.functions), failed], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def calls(self):
        path = self.state / "calls"
        return path.read_text() if path.exists() else ""

    def test_missing_tailscale_is_skipped(self):
        out = self.run_check()
        self.assertNotIn("Tailscale", out)
        self.assertIn("failed=[]", out)

    def test_fixed_and_newer_versions_are_left_alone(self):
        for version in ("1.104.2", "1.104.10", "1.110.0", "2.0.0"):
            with self.subTest(version=version):
                self.install(version, daemon=version + "-tabc-gdef")
                (self.state / "sudo-ok").touch()
                self.stub("sudo", SUDO)
                out = self.run_check()
                self.assertIn(f"Client {version}, daemon {version}", out)
                self.assertIn("has the fix", out)
                self.assertIn("failed=[]", out)
                self.assertNotIn("update", self.calls().replace("tailscale_update", ""))

    def test_old_version_updates_with_passwordless_sudo_and_checks_daemon(self):
        # 1.99.9 sorts after 1.104.2 as text, so this also checks numeric order.
        self.install("1.99.9", daemon="1.99.9-t1", new_client="1.104.3", new_daemon="1.104.3-t2")
        (self.state / "sudo-ok").touch()
        self.stub("sudo", SUDO)
        out = self.run_check()
        self.assertIn(f"sudo -n {self.bin}/tailscale update --yes", self.calls())
        self.assertIn("Now client 1.104.3, daemon 1.104.3", out)
        self.assertIn("failed=[]", out)

    def test_old_version_without_sudo_gives_manual_step(self):
        self.install("1.98.0", daemon="1.98.0")
        self.stub("sudo", SUDO)
        out = self.run_check()
        self.assertIn("Run sudo tailscale update", out)
        self.assertNotIn("update --yes", self.calls())
        self.assertIn("failed=[]", out)

    def test_lab_servers_never_try_sudo(self):
        self.install("1.98.0", daemon="1.98.0")
        (self.state / "sudo-ok").touch()
        self.stub("sudo", SUDO)
        self.env["CONFIGS_NO_AGENTS"] = "1"
        out = self.run_check()
        self.assertIn("Ask the server's admins", out)
        self.assertNotIn("sudo", self.calls())
        self.assertIn("failed=[]", out)

    def test_failed_trust_store_skips_update(self):
        self.install("1.98.0", daemon="1.98.0", new_client="1.104.2")
        (self.state / "sudo-ok").touch()
        self.stub("sudo", SUDO)
        out = self.run_check(failed=" trust-store")
        self.assertIn("Client 1.98.0, daemon 1.98.0", out)
        self.assertIn("Skipped the update, because the trust store check failed", out)
        self.assertNotIn("update --yes", self.calls())

    def test_failed_update_fails(self):
        self.install("1.98.0", daemon="1.98.0")
        (self.state / "sudo-ok").touch()
        (self.state / "update-fails").touch()
        self.stub("sudo", SUDO)
        out = self.run_check()
        self.assertIn("Could not update Tailscale", out)
        self.assertIn("failed=[ tailscale]", out)

    def test_update_that_leaves_old_client_fails(self):
        self.install("1.98.0", new_client="1.98.0")
        (self.state / "sudo-ok").touch()
        self.stub("sudo", SUDO)
        out = self.run_check()
        self.assertIn("still older than 1.104.2", out)
        self.assertIn("failed=[ tailscale]", out)

    def test_update_that_leaves_old_daemon_running_fails(self):
        self.install("1.98.0", daemon="1.98.0", new_client="1.104.2")
        (self.state / "sudo-ok").touch()
        self.stub("sudo", SUDO)
        out = self.run_check()
        self.assertIn("tailscaled is 1.98.0 after the update; sudo systemctl restart tailscaled", out)
        self.assertIn("failed=[ tailscale]", out)

    def test_daemon_that_stops_answering_after_update_fails(self):
        self.install("1.98.0", daemon="1.98.0", new_client="1.104.2")
        (self.state / "sudo-ok").touch()
        self.stub("sudo", SUDO)
        # The update leaves no daemon running.
        self.stub("tailscale", TAILSCALE.replace('cp "$STATE/new-client"', 'rm "$STATE/daemon"; cp "$STATE/new-client"'))
        out = self.run_check()
        self.assertIn("tailscaled is not answering", out)
        self.assertIn("failed=[ tailscale]", out)

    def test_stopped_daemon_is_not_required_after_update(self):
        self.install("1.98.0", new_client="1.104.2")
        (self.state / "sudo-ok").touch()
        self.stub("sudo", SUDO)
        out = self.run_check()
        self.assertIn("Now client 1.104.2, daemon unavailable", out)
        self.assertIn("daemon version could not be verified", out)
        self.assertIn("failed=[]", out)

    def test_old_daemon_first_seen_after_update_fails(self):
        self.install("1.98.0", new_client="1.104.2", new_daemon="1.98.0")
        (self.state / "sudo-ok").touch()
        self.stub("sudo", SUDO)
        out = self.run_check()
        self.assertIn("tailscaled is 1.98.0 after the update", out)
        self.assertIn("failed=[ tailscale]", out)

    def test_fixed_client_with_unavailable_daemon_does_not_claim_verified(self):
        self.install("1.104.2")
        out = self.run_check()
        self.assertIn("daemon version could not be verified", out)
        self.assertNotIn("Tailscale has the fix", out)
        self.assertNotIn("not running", out)
        self.assertNotIn("update --yes", self.calls())

    def test_fixed_client_with_old_daemon_asks_for_restart(self):
        self.install("1.104.2", daemon="1.98.0")
        out = self.run_check()
        self.assertIn("tailscaled is still running 1.98.0; sudo systemctl restart tailscaled", out)
        self.assertNotIn("update --yes", self.calls())
        self.assertIn("failed=[]", out)

    def test_unreadable_version_fails(self):
        self.stub("tailscale", "echo garbage\n")
        out = self.run_check()
        self.assertIn("Could not read the version", out)
        self.assertIn("failed=[ tailscale]", out)

    def test_mac_app_is_left_to_the_app_store(self):
        self.install("1.98.0", daemon="1.98.0")
        (self.bin / "tailscale").rename(self.mac_app)
        self.stub("uname", "echo Darwin\n")
        self.stub("sudo", SUDO)
        (self.state / "sudo-ok").touch()
        out = self.run_check()
        self.assertIn("App Store", out)
        self.assertNotIn("update --yes", self.calls())
        self.assertIn("failed=[]", out)

    def test_homebrew_tailscale_upgrades_with_brew(self):
        prefix = self.root / "brew"
        (prefix / "bin").mkdir(parents=True)
        self.stub("tailscale", TAILSCALE, prefix / "bin")
        (self.state / "client").write_text("1.98.0\n")
        (self.state / "new-client").write_text("1.104.2\n")
        self.stub("brew", BREW, prefix / "bin")
        self.stub("uname", "echo Darwin\n")
        self.env.update(PATH=f"{prefix}/bin:{self.bin}", BREW_PREFIX=str(prefix))
        out = self.run_check()
        self.assertIn("brew upgrade tailscale", self.calls())
        self.assertNotIn("sudo", self.calls())
        self.assertIn("Now client 1.104.2", out)
        self.assertIn("failed=[]", out)


if __name__ == "__main__":
    unittest.main()
