"""Offline checks of the public setup and config-link commands."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent


class SetupChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="configs-setup-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        shutil.copytree(REPO, self.repo, ignore=shutil.ignore_patterns(".git", "__pycache__"))
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "add", "nvim"], check=True)
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = {"HOME": str(self.home), "PATH": os.defpath, "LANG": "C", "HOSTNAME": "server"}

    def run_script(self, name, *args, ok=True):
        result = subprocess.run(["bash", str(self.repo / name), *args], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def test_setup_orders_storage_tools_and_links_and_reruns(self):
        # Substitute only the external installer; setup and linking run normally.
        (self.repo / "install-tools.sh").write_text('''set -e
[ -d "$XDG_DATA_HOME" ]
[ -d "$XDG_STATE_HOME" ]
[ -d "$XDG_CACHE_HOME" ]
[ -d "$NVM_DIR" ]
[ ! -e "$HOME/.bashrc" ] || [ -L "$HOME/.bashrc" ]
echo called >> "$HOME/installer-calls"
''')
        self.env.update(XDG_DATA_HOME=str(self.root / "data"),
                        XDG_STATE_HOME=str(self.root / "state"),
                        XDG_CACHE_HOME=str(self.root / "cache"))
        for _ in range(2):
            result = self.run_script("setup.sh")
            self.assertIn("Setup complete", result.stdout)
            self.assertTrue((self.home / ".bashrc").is_symlink())
        self.assertEqual((self.home / "installer-calls").read_text(), "called\ncalled\n")
        self.assertFalse((self.home / ".config/hypr").exists())
        self.assertTrue((self.home / ".config/nvim/init.lua").exists())

    def test_linker_preserves_local_files_and_backs_up_replacements_once(self):
        snippets = self.home / ".bashrc.d"
        snippets.mkdir()
        (snippets / "99-local.sh").write_text("# local\n")
        (self.home / ".bashrc").write_text("# original\n")
        nvim = self.home / ".config/nvim"
        nvim.mkdir(parents=True)
        (nvim / "init.lua").write_text("-- original\n")
        (nvim / "lazy-lock.json").write_text("{}\n")
        (nvim / "local.lua").write_text("-- personal\n")
        self.run_script("link.sh")
        self.assertEqual((nvim / "local.lua").read_text(), "-- personal\n")
        self.assertEqual((nvim / "lazy-lock.json").read_text(), "{}\n")
        self.assertEqual((snippets / "99-local.sh").read_text(), "# local\n")
        backups = self.home / ".local/state/configs/config-backups"
        saved = list(backups.iterdir())
        self.assertEqual(len(saved), 1)
        self.assertEqual((saved[0] / "home/.bashrc").read_text(), "# original\n")
        self.assertEqual((saved[0] / "config/nvim/init.lua").read_text(), "-- original\n")
        self.run_script("link.sh")
        self.assertEqual(list(backups.iterdir()), saved)


    def test_migration_moves_known_data_once_and_never_installs(self):
        self.env["HOSTNAME"] = "yixing"
        storage = self.root / "storage"
        old = storage / ".local"
        (old / "nvim").mkdir(parents=True)
        (old / "nvim/history").write_text("history")
        (old / "personal").mkdir()
        (self.repo / "migrations/yixing.sh").write_text(
            (self.repo / "migrations/yixing.sh").read_text().replace(
                "/mnt/ultracube/earmand", str(storage)))
        (self.repo / "install-tools.sh").write_text("exit 99\n")
        self.run_script("migrations/yixing.sh", "--apply")
        self.assertEqual((old / "share/nvim/history").read_text(), "history")
        self.assertTrue((old / "personal").is_dir())
        self.assertFalse((self.home / ".bashrc").exists())
        (old / "nvim").mkdir()
        (old / "nvim/new-local").write_text("stay here")
        self.run_script("migrations/yixing.sh", "--apply")
        self.assertEqual((old / "nvim/new-local").read_text(), "stay here")


    def test_switching_checkouts_preserves_local_nvim_and_old_checkout(self):
        old = self.root / "old"
        shutil.copytree(self.repo / "nvim", old / "nvim")
        (old / "nvim/lazy-lock.json").write_text('{"local": true}\n')
        (old / "nvim/local.lua").write_text("-- personal\n")
        config = self.home / ".config"
        config.mkdir()
        # A relative directory link must be copied before moving its link.
        (config / "nvim").symlink_to("../../old/nvim")
        self.run_script("link.sh")
        self.assertFalse((config / "nvim").is_symlink())
        self.assertTrue((config / "nvim/init.lua").is_symlink())
        self.assertFalse((old / "nvim/init.lua").is_symlink())
        self.assertEqual((config / "nvim/local.lua").read_text(), "-- personal\n")
        self.assertEqual((config / "nvim/lazy-lock.json").read_text(), '{"local": true}\n')
        self.run_script("link.sh")

    def test_required_failure_stops_before_linking_and_reports_phase(self):
        (self.repo / "install-tools.sh").write_text("echo failed-tool >&2\nexit 7\n")
        result = self.run_script("setup.sh", ok=False)
        self.assertEqual(result.returncode, 7)
        self.assertIn("tool installation", result.stderr)
        self.assertNotIn("Setup complete", result.stdout)
        self.assertFalse((self.home / ".bashrc").exists())

    def test_desktop_selection_and_mac_platform(self):
        (self.home / ".local/share/hyprkarl").mkdir(parents=True)
        self.run_script("link.sh")
        self.assertTrue((self.home / ".config/hypr/hyprland.local.lua").is_symlink())
        # A Mac can keep a Hyprkarl checkout without applying its desktop configs.
        shutil.rmtree(self.home / ".config/hypr")
        commands = self.root / "commands"
        commands.mkdir()
        uname = commands / "uname"
        uname.write_text('case "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n')
        uname.chmod(0o755)
        self.env["PATH"] = str(commands) + ":" + os.defpath
        (self.repo / "install-tools.sh").write_text("exit 0\n")
        self.run_script("setup.sh")
        self.assertFalse((self.home / ".config/hypr").exists())
        uname.write_text("echo unsupported\n")
        result = self.run_script("setup.sh", ok=False)
        self.assertIn("Supported platforms", result.stderr)

    def test_storage_collision_and_missing_drive_stop_setup(self):
        self.env["HOSTNAME"] = "yixing"
        storage = self.root / "storage"
        for relative in (".bashrc.d/05-machines.sh", "migrations/yixing.sh"):
            path = self.repo / relative
            path.write_text(path.read_text().replace("/mnt/ultracube/earmand", str(storage)))
        (self.repo / "install-tools.sh").write_text('touch "$HOME/installer-called"\n')
        result = self.run_script("setup.sh", ok=False)
        self.assertIn("drive mounted", result.stderr)
        self.assertFalse(storage.exists())
        (storage / ".local/nvim").mkdir(parents=True)
        (storage / ".local/share/nvim").mkdir(parents=True)
        self.run_script("setup.sh", ok=False)
        self.assertFalse((self.home / "installer-called").exists())
        self.assertFalse((storage / ".local/state/configs/storage-layout-v1").exists())
        (storage / ".local/share/nvim").rmdir()
        self.run_script("setup.sh")
        self.assertTrue((self.home / "installer-called").exists())
        self.assertTrue((self.home / ".bashrc").is_symlink())


    def test_link_failure_reports_incomplete_setup(self):
        (self.repo / "install-tools.sh").write_text("exit 0\n")
        commands = self.root / "commands"
        commands.mkdir()
        linker = commands / "ln"
        linker.write_text("#!/bin/sh\necho cannot-link >&2\nexit 9\n")
        linker.chmod(0o755)
        self.env["PATH"] = str(commands) + ":" + os.defpath
        result = self.run_script("setup.sh", ok=False)
        self.assertIn("config linking", result.stderr)
        self.assertNotIn("Setup complete", result.stdout)

    def test_luogeng_prepares_temp_and_migrates_history_before_tools(self):
        self.env["HOSTNAME"] = "luogeng"
        storage = self.root / "storage"
        (storage / ".local").mkdir(parents=True)
        (storage / ".local/lesshst").write_text("history")
        (storage / ".local/starship").write_text("old binary")
        for relative in (".bashrc.d/05-machines.sh", "migrations/luogeng.sh"):
            path = self.repo / relative
            path.write_text(path.read_text().replace("/media/earmand", str(storage)))
        (self.repo / "install-tools.sh").write_text('set -e\n. "$(dirname "$0")/.bashrc.d/05-machines.sh"\n[ -d "$TMPDIR" ]\n[ -f "$XDG_STATE_HOME/lesshst" ]\n[ -d "$NVM_DIR" ]\n')
        self.run_script("migrations/luogeng.sh")
        self.assertFalse((storage / "tmp").exists())
        self.run_script("setup.sh")
        self.assertEqual((storage / ".local/state/lesshst").read_text(), "history")
        saved = list((storage / ".local/state/configs/migration-backups").glob("*/starship"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0].read_text(), "old binary")
        self.run_script("setup.sh")



if __name__ == "__main__":
    unittest.main()
