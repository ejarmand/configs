"""Offline checks of the download step in hyprkarl/apps/t3code-remote-update.sh.

Only the script each host runs is tested, locally, in a fake home whose path
has a space. Its PATH holds links to harmless real tools and stubs: curl and
wget copy fixture files and log their arguments, and nothing reaches SSH,
systemd, other processes or the network. --no-restart stops after the
download, so no service is touched.
"""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
VERSION = "1.2.3"
ARCHIVE = f"t3-{VERSION}-linux-x64.tar.gz"
REAL = ("sh", "bash", "sed", "cat", "mkdir", "rm", "mv", "mktemp", "awk", "ls", "tar", "gzip", "sha256sum",
        "cut", "tr", "grep", "head", "tail", "date", "id", "sleep", "cp")
# Logs each argument on its own line, then copies the file the URL names.
FETCH = r'''#!/bin/sh
{ echo "${0##*/} SSL_CERT_FILE=$SSL_CERT_FILE SSL_CERT_DIR=$SSL_CERT_DIR"; for a; do echo "$a"; done; echo --; } >> "$STATE/fetches"
out= url= prev=
for a; do
  [ "$prev" = -o ] || [ "$prev" = -O ] && out=$a
  case $a in https://*) url=$a ;; esac
  prev=$a
done
cp "$FIXTURES/${url##*/}" "$out"
'''


def remote_script():
    text = (REPO / "hyprkarl/apps/t3code-remote-update.sh").read_text()
    return text.split("remote_script=$(cat <<'REMOTE'\n", 1)[1].split("\nREMOTE\n)", 1)[0] + "\n"


class RemoteDownloadChecks(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="configs-t3-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.home = self.root / "home dir"
        self.state = self.root / "state"
        self.fixtures = self.root / "fixtures"
        self.bin = self.root / "bin"
        for path in (self.home, self.state, self.fixtures, self.bin):
            path.mkdir()
        for name in REAL:
            os.symlink(shutil.which(name), self.bin / name)
        self.stub("uname", 'case "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac\n')
        self.stub("pgrep", "exit 1\n")
        self.stub("ps", "exit 0\n")
        self.stub("flock", "exit 0\n")
        self.stub("loginctl", "echo yes\n")
        self.stub("systemctl", "exit 0\n")
        self.stub("ssh", 'echo "ssh $*" >> "$STATE/fetches"; exit 1\n')
        self.stub("curl", FETCH)
        self.stub("wget", FETCH)
        # A service from an earlier run, so the host isn't skipped as running no t3.
        unit = self.home / ".config/systemd/user/t3code.service"
        unit.parent.mkdir(parents=True)
        unit.write_text("")
        (self.home / ".t3").mkdir()
        self.release()
        self.script = self.root / "remote.sh"
        self.script.write_text(remote_script())
        self.ca = self.home / ".local/share/configs"
        self.env = {"HOME": str(self.home), "PATH": str(self.bin), "LANG": "C", "STATE": str(self.state),
                    "FIXTURES": str(self.fixtures), "TMPDIR": str(self.root)}

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(body if body.startswith("#!") else "#!/bin/sh\n" + body)
        path.chmod(0o755)

    def release(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w:gz") as tar:
            body = f"#!/bin/sh\necho 't3 {VERSION}'\n".encode()
            info = tarfile.TarInfo("package/t3")
            info.size, info.mode = len(body), 0o755
            tar.addfile(info, io.BytesIO(body))
        (self.fixtures / ARCHIVE).write_bytes(data.getvalue())
        (self.fixtures / "SHA256SUMS").write_text(f"{hashlib.sha256(data.getvalue()).hexdigest()}  {ARCHIVE}\n")

    def checked_store(self):
        (self.ca / "no-ca-dir").mkdir(parents=True)
        (self.ca / "ca-bundle.pem").write_text("-----BEGIN CERTIFICATE-----\n")

    def run_remote(self, mode, ok=True):
        result = subprocess.run([str(self.bin / "sh"), str(self.script), VERSION, mode], env=self.env,
                                text=True, capture_output=True)
        out = result.stdout + result.stderr
        self.assertEqual(result.returncode == 0, ok, out)
        return out

    def fetches(self):
        path = self.state / "fetches"
        return path.read_text() if path.exists() else ""

    def assert_downloaded(self, out):
        self.assertIn(f"OK: t3@{VERSION} downloaded", out)
        self.assertTrue((self.home / f".t3/runtime/versions/{VERSION}/t3").exists(), out)

    def test_curl_uses_only_the_checked_store(self):
        self.checked_store()
        out = self.run_remote("download")
        self.assert_downloaded(out)
        calls = self.fetches().split("--\n")[:-1]
        self.assertEqual(len(calls), 2, out)
        for call in calls:
            lines = call.splitlines()
            self.assertEqual(lines[0], f"curl SSL_CERT_FILE={self.ca}/ca-bundle.pem SSL_CERT_DIR={self.ca}/no-ca-dir")
            # -q must come first for curl to skip the user's curlrc.
            self.assertEqual(lines[1], "-q")
            args = lines[1:]
            self.assertEqual(args[args.index("--cacert") + 1], f"{self.ca}/ca-bundle.pem")
            self.assertEqual(args[args.index("--capath") + 1], f"{self.ca}/no-ca-dir")

    def test_wget_uses_only_the_checked_store(self):
        self.checked_store()
        (self.bin / "curl").unlink()
        out = self.run_remote("download")
        self.assert_downloaded(out)
        calls = self.fetches().split("--\n")[:-1]
        self.assertEqual(len(calls), 2, out)
        for call in calls:
            lines = call.splitlines()
            self.assertTrue(lines[0].startswith("wget SSL_CERT_FILE="), lines)
            self.assertEqual(lines[1], "--no-config")
            self.assertIn(f"--ca-certificate={self.ca}/ca-bundle.pem", lines)
            self.assertIn(f"--ca-directory={self.ca}/no-ca-dir", lines)

    def test_download_without_a_checked_store_is_refused(self):
        cases = {
            "no bundle": lambda: (self.ca / "no-ca-dir").mkdir(parents=True),
            "empty bundle": lambda: (self.checked_store(), (self.ca / "ca-bundle.pem").write_text("")),
            "no CA directory": lambda: (self.checked_store(), (self.ca / "no-ca-dir").rmdir()),
            "CA directory not empty": lambda: (self.checked_store(), (self.ca / "no-ca-dir/root.pem").write_text("")),
        }
        for name, setup in cases.items():
            with self.subTest(name):
                shutil.rmtree(self.ca, ignore_errors=True)
                setup()
                out = self.run_remote("download", ok=False)
                self.assertIn(f"FAILED: no checked trust store here: needs {self.ca}/ca-bundle.pem", out)
                self.assertIn("setup.sh or config-update", out)
                self.assertEqual(self.fetches(), "")
                self.assertFalse((self.home / f".t3/runtime/versions/{VERSION}").exists())

    def test_dry_run_reports_a_missing_store_without_downloading(self):
        out = self.run_remote("dry")
        self.assertIn(f"would download t3@{VERSION}", out)
        self.assertIn("so the real run would stop here", out)
        self.assertEqual(self.fetches(), "")
        self.checked_store()
        self.assertNotIn("would stop here", self.run_remote("dry"))
        self.assertEqual(self.fetches(), "")

    def test_downloaded_release_needs_no_store_or_downloader(self):
        runtime = self.home / f".t3/runtime/versions/{VERSION}"
        runtime.mkdir(parents=True)
        (runtime / "t3").write_text("#!/bin/sh\n")
        (runtime / "t3").chmod(0o755)
        (runtime / ".install-complete").write_text(VERSION + "\n")
        (self.bin / "curl").unlink()
        (self.bin / "wget").unlink()
        out = self.run_remote("download")
        self.assertIn(f"t3@{VERSION} already downloaded", out)
        self.assertIn(f"OK: t3@{VERSION} downloaded", out)
        self.assertIn("already downloaded", self.run_remote("dry"))
        self.assertEqual(self.fetches(), "")


if __name__ == "__main__":
    unittest.main()
