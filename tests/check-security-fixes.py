"""Offline checks of install/security-fixes.sh's trust store, pip, npm,
LiteLLM and file permission steps, and of the order main runs them in.

The script's functions are loaded into a fake home. The PATH holds only links
to harmless real tools, including the openssl that checks bundles against the
repo's forged chains, and stubs that log their calls. curl can't connect, and
sudo, brew, docker, tailscale, ssh, wget and package managers never reach the
real ones, so nothing touches the network or the system.
"""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
SYSTEM_BUNDLE = Path("/etc/ssl/certs/ca-certificates.crt")
CHAINS = REPO / "install/emudhra-chains"
# Real commands the script may run; everything else on its PATH is a stub.
REAL = ("bash", "sh", "openssl", "awk", "sed", "grep", "find", "sort", "mkdir", "rm", "mv", "cp", "ln",
        "cat", "base64", "ls", "mktemp", "chmod", "ps", "id", "uname", "head", "tr", "wc", "cksum", "cut",
        "readlink", "date")
# Stubs that log "NAME ARGS" and fail, unless a test replaces them.
STUBS = ("curl", "wget", "sudo", "brew", "docker", "tailscale", "ssh", "apt-get", "dnf", "yum",
         "update-ca-certificates", "keytool", "python", "python3", "pip", "node", "uv")
LOG = 'echo "${0##*/} $*" >> "$CALLS"\n'

TAILSCALE = LOG + '''case "$*" in
  version) cat "$STATE/client" ;;
  "version --daemon") echo "Daemon: $(cat "$STATE/client")" ;;
  "update --yes") echo 1.104.2 > "$STATE/client" ;;
  *) exit 2 ;;
esac
'''
SUDO = LOG + '[ "$1" = -n ] || exit 1\nshift\n[ "$*" = true ] || exec "$@"\n'
AUTH_SUDO = LOG + '''case "$*" in
  "-n true") [ -e "$STATE/authenticated" ] ;;
  "-v") [ ! -e "$STATE/declined" ] || exit 130
    : > "$STATE/authenticated" ;;
  *) [ "$1" = -n ] && [ -e "$STATE/authenticated" ] || exit 1
    shift; export FIXTURE_ROOT=1; exec "$@" ;;
esac
'''


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
        self.state = self.root / "state"
        self.state.mkdir()
        self.calls_file = self.state / "calls"
        for name in REAL:
            os.symlink(shutil.which(name), self.bin / name)
        for name in STUBS:
            self.stub(name, LOG + ("exit 7\n" if name == "curl" else "exit 1\n"))
        self.stub("docker", LOG + 'case "$1 $2" in "context inspect") echo unix:///var/run/docker.sock ;; *) exit 1 ;; esac\n')
        script = (REPO / "install/security-fixes.sh").read_text()
        # Keep the absolute Homebrew and Mac app paths inside the fixture too.
        for path in ("/home/linuxbrew/.linuxbrew/bin/brew", "/opt/homebrew/bin/brew", "/usr/local/bin/brew",
                     "/Applications/Tailscale.app/Contents/MacOS/Tailscale"):
            self.assertIn(path, script)
            script = script.replace(path, str(self.root / "absent" / path.lstrip("/")))
        self.functions = self.root / "functions.sh"
        self.functions.write_text(script.rsplit("\nmain\n", 1)[0] + "\n")
        self.env = {"HOME": str(self.home), "PATH": str(self.bin), "LANG": "C", "TMPDIR": str(self.root),
                    "XDG_DATA_HOME": str(self.home / ".local/share"), "CALLS": str(self.calls_file),
                    "STATE": str(self.state)}
        self.bundle = self.home / ".local/share/configs/ca-bundle.pem"

    def stub(self, name, body, directory=None):
        path = (directory or self.bin) / name
        if path.is_symlink() or path.exists():
            path.unlink()
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def calls(self):
        return self.calls_file.read_text() if self.calls_file.exists() else ""

    def run_steps(self, steps, ok=True, terminal=False, **env):
        # Only the fixture's commands, the repo's chains and its ca-env.sh,
        # whatever the real paths hold.
        body = (f'set --; . "{self.functions}"\n'
                f'pick() {{ [ -x "{self.bin}/$1" ] && echo "{self.bin}/$1"; }}\n'
                f'CHAINS="{CHAINS}" CONFIGS_REPO="{REPO}"\n{steps}\n'
                '[ -z "$failed" ] || { echo "failed:$failed" >&2; exit 1; }\n')
        master, slave = os.openpty() if terminal else (None, None)
        try:
            result = subprocess.run([shutil.which("bash"), "-c", body], env={**self.env, **env}, text=True,
                                    stdout=subprocess.PIPE, stderr=slave if terminal else subprocess.PIPE,
                                    timeout=30)
            errors = result.stderr or ""
            if terminal:
                os.close(slave)
                slave = None
                while True:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    errors += chunk.decode()
            out = result.stdout + errors
            self.assertEqual(result.returncode == 0, ok, out)
            return out
        finally:
            for fd in (master, slave):
                if fd is not None:
                    os.close(fd)

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
        self.assertIn("No known indicators", out)
        (site / "cook.pth").write_text("import cook\n")
        out = self.run_steps("litellm", ok=False)
        self.assertIn("cook.pth", out)
        self.assertNotIn("sitecustomize.py", out)
        self.assertNotIn("Not checked", out)

    def test_litellm_docker_image_fails(self):
        self.stub("docker", LOG + '''case "$1 $2" in
  "context inspect") echo unix:///var/run/docker.sock ;;
  *) echo "litellm:main-latest sha256:1bbcb1443bc962e45f5aad53fe3d2c30600e0379715fb6c664cdd3ac126c339e" ;;
esac
''')
        out = self.run_steps("litellm", ok=False)
        self.assertIn("Docker image litellm:main-latest", out)

    def test_clean_litellm_scan_says_what_it_did_not_check(self):
        (self.home / "projects").mkdir()
        out = self.run_steps("litellm")
        self.assertIn(f"  {self.home}/projects", out)
        self.assertIn("not a clean bill of health", out)
        self.assertIn("Docker images: could not list them", out)
        self.assertIn("including network mounts", out)
        self.assertIn("pip's HTTP cache", out)
        self.assertIn("treat this machine's credentials as stolen", out)
        self.assertNotIn("No traces found", out)
        (self.bin / "docker").unlink()
        self.assertIn("Docker images: no docker command", self.run_steps("litellm"))

    @unittest.skipIf(os.geteuid() == 0, "root reads everything")
    def test_unreadable_directory_is_reported(self):
        locked = self.home / "projects/locked"
        locked.mkdir(parents=True)
        locked.chmod(0)
        self.addCleanup(locked.chmod, 0o700)
        out = self.run_steps("litellm")
        self.assertIn(f"Parts of {self.home}/projects: no permission to read them", out)

    # main, end to end. Each adds an old Node and Tailscale and passwordless
    # sudo, so any step that runs or updates them leaves a call in the log.
    def machine(self, system_bundle):
        node = self.home / ".nvm/versions/node/v24.22.0/bin/node"
        node.parent.mkdir(parents=True)
        node.write_text("#!/bin/sh\n" + LOG + "echo v24.22.0\n")
        node.chmod(0o755)
        (self.state / "client").write_text("1.98.0\n")
        self.stub("tailscale", TAILSCALE)
        self.stub("sudo", SUDO)
        # Homebrew with ca-certificates, whose generated bundle is the clean system one.
        prefix = self.root / "brew"
        (prefix / "etc/ca-certificates").mkdir(parents=True)
        shutil.copy(SYSTEM_BUNDLE, prefix / "etc/ca-certificates/cert.pem")
        self.stub("brew", LOG + f'case "$1" in --prefix) echo "{prefix}" ;; esac\n')
        return {"SYSTEM_CA_BUNDLE": str(system_bundle)}

    def test_litellm_trace_stops_before_anything_downloads_or_runs(self):
        env = self.machine(SYSTEM_BUNDLE)
        site = self.home / ".venv/lib/python3.12/site-packages"
        site.mkdir(parents=True)
        (site / "cook.pth").write_text("import cook\n")
        out = self.run_steps("main", ok=False, **env)
        self.assertIn("Stopped before the trust store", out)
        self.assertFalse(self.bundle.exists(), out)
        # docker only lists images; nothing else ran.
        self.assertEqual([c for c in self.calls().splitlines() if not c.startswith("docker ")], [], out)

    def test_failed_trust_store_skips_homebrew_and_tailscale_updates(self):
        corrupt = self.write_bundle("corrupt.pem", certs(SYSTEM_BUNDLE) +
                                    ["-----BEGIN CERTIFICATE-----\nnotbase64\n-----END CERTIFICATE-----\n"])
        env = self.machine(corrupt)
        out = self.run_steps("main", ok=False, **env)
        calls = self.calls()
        self.assertIn("Skipped the upgrade, because the trust store check failed", out)
        self.assertIn("Skipped the update, because the trust store check failed", out)
        for call in ("brew update", "brew upgrade", "tailscale update", "curl"):
            self.assertNotIn(call, calls, out)
        # Local-only steps still run.
        self.assertIn("Node v24.22.0, fixed in 24.22.1", out)
        self.assertIn("== Private files", out)

    def test_failed_homebrew_store_skips_brew_tailscale_update(self):
        prefix = self.root / "brew"
        (prefix / "bin").mkdir(parents=True)
        (self.state / "client").write_text("1.98.0\n")
        self.stub("tailscale", TAILSCALE, prefix / "bin")
        self.stub("brew", LOG + f'case "$1" in --prefix) echo "{prefix}" ;; esac\n', prefix / "bin")
        out = self.run_steps('failed=" homebrew"; tailscale_update; failed=', PATH=f"{prefix}/bin:{self.bin}")
        self.assertIn("Skipped brew upgrade tailscale", out)
        self.assertNotIn("upgrade", self.calls())

    def test_passing_checks_go_on_to_the_updates(self):
        env = self.machine(SYSTEM_BUNDLE)
        out = self.run_steps("main", **env)
        calls = self.calls().splitlines()
        self.assertTrue(self.bundle.is_symlink(), out)
        for call in ("brew update --quiet", "brew upgrade ca-certificates",
                     f"sudo -n {self.bin}/tailscale update --yes"):
            self.assertIn(call, calls, out)
        # The LiteLLM check came first, before anything else ran.
        self.assertTrue(calls[0].startswith("docker "), calls)
        self.assertIn("Now client 1.104.2", out)
        self.assertIn("not a clean bill of health", out)

    def test_private_files_lose_group_and_other_access(self):
        ssh = self.home / ".ssh"
        ssh.mkdir(mode=0o755)
        (ssh / "id_ed25519").write_text("")
        (ssh / "id_ed25519").chmod(0o644)
        self.run_steps("private_files")
        self.assertEqual(ssh.stat().st_mode & 0o777, 0o700)
        self.assertEqual((ssh / "id_ed25519").stat().st_mode & 0o777, 0o600)

    def test_sudo_prompts_in_terminal_and_reuses_authentication_on_lab_host(self):
        self.stub("id", "echo 1000\n")
        self.stub("sudo", AUTH_SUDO)
        out = self.run_steps('sudo_ready "check certificates"; sudo_ready "update Tailscale"',
                             terminal=True, CONFIGS_NO_AGENTS="1")
        self.assertIn("Sudo is needed to check certificates", out)
        self.assertEqual(self.calls().splitlines().count("sudo -v"), 1)

    def test_declined_sudo_continues_without_repeated_prompts(self):
        self.stub("id", "echo 1000\n")
        self.stub("sudo", AUTH_SUDO)
        (self.state / "declined").touch()
        out = self.run_steps('sudo_ready "check certificates" || echo skipped; sudo_ready "update Tailscale" || echo continued',
                             terminal=True)
        self.assertIn("continued", out)
        self.assertIn("continuing without privileged steps", out)
        self.assertEqual(self.calls().splitlines().count("sudo -v"), 1)

    def test_interrupt_at_sudo_prompt_continues(self):
        self.stub("id", "echo 1000\n")
        self.stub("sudo", LOG + 'if [ "$1" = -v ]; then kill -INT "$PPID"; exit 130; fi; exit 1\n')
        out = self.run_steps('sudo_ready "check certificates" || echo continued', terminal=True)
        self.assertIn("continued", out)
        self.assertIn("continuing without privileged steps", out)

    def test_system_ca_update_prompts_even_on_lab_host(self):
        self.stub("id", "echo 1000\n")
        self.stub("sudo", AUTH_SUDO)
        self.stub("apt-get", LOG + "exit 0\n")
        self.run_steps("upgrade_system_store", terminal=True, CONFIGS_NO_AGENTS="1")
        self.assertIn("sudo -v", self.calls())
        self.assertIn("--only-upgrade ca-certificates", self.calls())

    def test_tailscale_update_prompts_and_verifies_result(self):
        self.machine(SYSTEM_BUNDLE)
        self.stub("id", "echo 1000\n")
        self.stub("sudo", AUTH_SUDO)
        out = self.run_steps("tailscale_update", terminal=True, CONFIGS_NO_AGENTS="1")
        self.assertIn("sudo -v", self.calls())
        self.assertIn("Now client 1.104.2, daemon 1.104.2", out)

    def test_scan_prunes_directories_owned_by_other_accounts(self):
        site = self.home / "projects/other-account"
        site.mkdir(parents=True)
        (site / "cook.pth").write_text("import cook\n")
        # Simulate a caller who doesn't own this tree, without chown or sudo.
        self.stub("id", f"echo {os.getuid() + 10000}\n")
        out = self.run_steps("litellm")
        self.assertNotIn("Found traces", out)

    def test_unattended_sudo_does_not_prompt(self):
        self.stub("id", "echo 1000\n")
        self.stub("sudo", AUTH_SUDO)
        out = self.run_steps('sudo_ready "check certificates" || echo skipped')
        self.assertIn("skipped", out)
        self.assertNotIn("sudo -v", self.calls())

    def test_root_does_not_need_sudo(self):
        self.stub("id", "echo 0\n")
        self.run_steps('sudo_ready "check certificates"; "${SUDO[@]}" true')
        self.assertNotIn("sudo", self.calls())

    def test_remote_docker_endpoint_is_not_contacted(self):
        out = self.run_steps("litellm", DOCKER_HOST="ssh://another-host")
        self.assertIn("remote or unknown endpoint", out)
        self.assertNotIn("docker ", self.calls())
        self.assertNotIn("sudo", self.calls())

    def test_local_docker_retries_with_sudo_and_detects_bad_digest(self):
        # A fixture socket stands in for the system socket; no connection is made.
        sockpath = self.root / "docker.sock"
        sock = socket.socket(socket.AF_UNIX)
        sock.bind(str(sockpath))
        self.addCleanup(sock.close)
        self.functions.write_text(self.functions.read_text().replace("/var/run/docker.sock", str(sockpath)))
        (self.state / "authenticated").touch()
        self.stub("sudo", AUTH_SUDO)
        self.stub("docker", LOG + '''[ -n "$FIXTURE_ROOT" ] || exit 1
echo "litellm:bad sha256:1bbcb1443bc962e45f5aad53fe3d2c30600e0379715fb6c664cdd3ac126c339e"
''')
        out = self.run_steps("litellm", ok=False, DOCKER_HOST=f"unix://{sockpath}", CONFIGS_NO_AGENTS="1")
        self.assertIn("Docker image litellm:bad", out)
        self.assertIn(f"sudo -n {self.bin}/docker --host unix://{sockpath} images", self.calls())
        self.assertNotIn("sudo -n find", self.calls())

    def test_non_system_docker_socket_never_uses_sudo(self):
        out = self.run_steps("litellm", DOCKER_HOST="unix:///run/user/1234/docker.sock")
        self.assertIn("could not list them", out)
        self.assertNotIn("sudo", self.calls())


if __name__ == "__main__":
    unittest.main()
