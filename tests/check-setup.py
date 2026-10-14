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
        self.upstream = self.root / "skills-upstream"
        skill = self.upstream / "skills/example"
        (skill / "bin").mkdir(parents=True)
        (skill / "SKILL.md").write_text("# Example skill\n")
        (skill / "bin/example-tool").write_text("#!/bin/sh\necho example\n")
        (skill / "bin/example-tool").chmod(0o755)
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.upstream)], check=True)
        self.commit(self.upstream)
        # Exercise real clone/pull without GitHub access or the user's checkout.
        self.env.update(GIT_CONFIG_COUNT="1",
                        GIT_CONFIG_KEY_0=f"url.{self.upstream}.insteadOf",
                        GIT_CONFIG_VALUE_0="https://github.com/ejarmand/skills.git")

    def commit(self, path):
        subprocess.run(["git", "-C", str(path), "add", "."], check=True)
        subprocess.run(["git", "-C", str(path), "-c", "user.name=Setup test",
                        "-c", "user.email=setup@example.invalid", "commit", "-qm", "Fixture"], check=True)

    def clone_configs(self):
        # The test repo copy becomes the upstream that config-update pulls from.
        self.commit(self.repo)
        clone = self.root / "configs clone"
        subprocess.run(["git", "clone", "-q", str(self.repo), str(clone)], check=True)
        return clone

    def run_script(self, name, *args, ok=True):
        result = subprocess.run(["bash", str(self.repo / name), *args], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def redirect_storage(self, hostname, original):
        self.env["HOSTNAME"] = hostname
        storage = self.root / "storage"
        for relative in (".bashrc.d/05-machines.sh", f"migrations/{hostname}.sh"):
            path = self.repo / relative
            path.write_text(path.read_text().replace(original, str(storage)))
        return storage

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

    def test_setup_pulls_and_links_skills_with_backups(self):
        (self.repo / "install-tools.sh").write_text("exit 0\n")
        skills = self.home / ".agents/skills"
        (skills / "example").mkdir(parents=True)
        (skills / "example/SKILL.md").write_text("local version")
        (skills / "personal").mkdir()
        (skills / "personal/SKILL.md").write_text("keep me")
        self.run_script("setup.sh")
        checkout = self.home / "projects/skills"
        for directory in (".agents/skills", ".claude/skills"):
            self.assertEqual((self.home / directory / "example").resolve(),
                             checkout / "skills/example")
        self.assertEqual((self.home / ".local/bin/example-tool").resolve(),
                         checkout / "skills/example/bin/example-tool")
        backups = list((self.home / ".local/state/configs/config-backups").glob(
            "*/home/.agents/skills/example/SKILL.md"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "local version")
        new = self.upstream / "skills/added"
        new.mkdir()
        (new / "SKILL.md").write_text("new skill")
        (self.upstream / "skills/example/SKILL.md").write_text("updated skill")
        self.commit(self.upstream)
        self.run_script("setup.sh")
        self.assertEqual((skills / "example/SKILL.md").read_text(), "updated skill")
        self.assertEqual((skills / "added/SKILL.md").read_text(), "new skill")
        self.assertEqual((skills / "personal/SKILL.md").read_text(), "keep me")
        self.assertFalse((self.home / ".claude/settings.json").exists())

    def test_diverged_skills_checkout_stops_without_resetting_local_work(self):
        (self.repo / "install-tools.sh").write_text("exit 0\n")
        checkout = self.root / "custom skills"
        self.env["SKILLS_REPO"] = str(checkout)
        self.run_script("setup.sh")
        (checkout / "local.txt").write_text("local work")
        self.commit(checkout)
        (self.upstream / "remote.txt").write_text("remote work")
        self.commit(self.upstream)
        (self.home / ".bashrc").unlink()
        result = self.run_script("setup.sh", ok=False)
        self.assertIn("skills update", result.stderr)
        self.assertNotIn("Setup complete", result.stdout)
        self.assertEqual((checkout / "local.txt").read_text(), "local work")
        self.assertFalse((checkout / "remote.txt").exists())
        self.assertFalse((self.home / ".bashrc").exists())
        self.assertFalse((self.home / "projects/skills").exists())

    def test_config_update_fast_forwards_then_runs_the_pulled_setup(self):
        (self.repo / "install-tools.sh").write_text("exit 0\n")
        clone = self.clone_configs()
        self.run_script(clone / "setup.sh")
        command = self.home / ".local/bin/config-update"
        self.assertEqual(command.resolve(), clone / "bin/config-update")
        (self.repo / "install-tools.sh").write_text('echo pulled >> "$HOME/installer-calls"\n')
        (self.repo / ".bashrc.d/50-pulled.sh").write_text("# pulled\n")
        # The pull rewrites the running command; shift its contents to prove that's safe.
        script = self.repo / "bin/config-update"
        script.write_text(script.read_text().replace("set -e\n", "set -e\n# Pulled.\n", 1))
        self.commit(self.repo)
        result = subprocess.run([str(command)], cwd=self.root, env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Setup complete", result.stdout)
        self.assertEqual((self.home / "installer-calls").read_text(), "pulled\n")
        self.assertEqual((self.home / ".bashrc.d/50-pulled.sh").resolve(),
                         clone / ".bashrc.d/50-pulled.sh")
        self.assertIn("# Pulled.", (clone / "bin/config-update").read_text())
        # A clone that is only ahead of upstream still runs setup on its commits.
        (clone / "install-tools.sh").write_text('echo local >> "$HOME/installer-calls"\n')
        self.commit(clone)
        head = subprocess.run(["git", "-C", str(clone), "rev-parse", "HEAD"],
                              text=True, capture_output=True, check=True).stdout
        result = self.run_script(command)
        self.assertIn("Setup complete", result.stdout)
        self.assertEqual((self.home / "installer-calls").read_text(), "pulled\nlocal\n")
        self.assertEqual(subprocess.run(["git", "-C", str(clone), "rev-parse", "HEAD"],
                                        text=True, capture_output=True, check=True).stdout, head)

    def test_config_update_stops_before_setup_when_pull_cannot_fast_forward(self):
        (self.repo / "install-tools.sh").write_text("exit 0\n")
        clone = self.clone_configs()
        command = clone / "bin/config-update"
        self.assertEqual(self.run_script(command, "extra", ok=False).returncode, 2)
        (self.repo / "install-tools.sh").write_text('touch "$HOME/installer-called"\n')
        (self.repo / "remote.txt").write_text("remote work")
        self.commit(self.repo)
        local = "# local work\nexit 0\n"
        (clone / "install-tools.sh").write_text(local)
        # A user's autostash and identity must not let the pull stash local edits.
        config = {"merge.autoStash": "true", "rebase.autoStash": "true",
                  "user.name": "Setup test", "user.email": "setup@example.invalid"}
        for index, (key, value) in enumerate(config.items(), start=1):
            self.env[f"GIT_CONFIG_KEY_{index}"] = key
            self.env[f"GIT_CONFIG_VALUE_{index}"] = value
        self.env["GIT_CONFIG_COUNT"] = str(len(config) + 1)

        def assert_stopped():
            result = self.run_script(command, ok=False)
            self.assertIn("The pull failed", result.stderr)
            self.assertNotIn("Setup complete", result.stdout)
            self.assertEqual((clone / "install-tools.sh").read_text(), local)
            self.assertFalse((clone / "remote.txt").exists())
            self.assertFalse((self.home / "installer-called").exists())
            self.assertFalse((self.home / ".bashrc").exists())
            stashes = subprocess.run(["git", "-C", str(clone), "stash", "list"],
                                     text=True, capture_output=True, check=True).stdout
            self.assertEqual(stashes, "")

        def head():
            return subprocess.run(["git", "-C", str(clone), "rev-parse", "HEAD"],
                                  text=True, capture_output=True, check=True).stdout

        assert_stopped()  # Uncommitted changes block the pull.
        self.commit(clone)
        local_head = head()
        assert_stopped()  # Diverged history.
        self.assertEqual(head(), local_head)

    def test_linker_puts_config_update_on_path_with_backup(self):
        command = self.home / ".local/bin/config-update"
        command.parent.mkdir(parents=True)
        command.write_text("old command\n")
        (self.repo / "bin/notes.txt").write_text("not a command\n")
        self.run_script("link.sh")
        self.assertFalse((command.parent / "notes.txt").exists())
        self.assertEqual(command.resolve(), self.repo / "bin/config-update")
        backups = list((self.home / ".local/state/configs/config-backups").glob(
            "*/home/.local/bin/config-update"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "old command\n")

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
        storage = self.redirect_storage("yixing", "/mnt/ultracube/earmand")
        old = storage / ".local"
        (old / "nvim").mkdir(parents=True)
        (old / "nvim/history").write_text("history")
        (old / "personal").mkdir()
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

    def test_switching_checkouts_preserves_local_symlink_referents(self):
        old = self.root / "old"
        (old / "nvim/nested").mkdir(parents=True)
        (old / "local.lua").write_text("-- personal\n")
        targets = {"local.lua": "../local.lua",
                   "nested/local.lua": "../../local.lua",
                   "dangling.lua": "../missing.lua",
                   "absolute.lua": str(old / "local.lua")}
        for relative, target in targets.items():
            (old / "nvim" / relative).symlink_to(target)
        config = self.home / ".config"
        config.mkdir()
        (config / "nvim").symlink_to("../../old/nvim")
        for _ in range(2):
            self.run_script("link.sh")
            for relative in ("local.lua", "nested/local.lua", "absolute.lua"):
                self.assertEqual((config / "nvim" / relative).read_text(), "-- personal\n")
            dangling = config / "nvim/dangling.lua"
            self.assertTrue(dangling.is_symlink())
            self.assertEqual(dangling.resolve(), old / "missing.lua")
            self.assertEqual(os.readlink(config / "nvim/absolute.lua"), targets["absolute.lua"])
            for relative, target in targets.items():
                self.assertEqual(os.readlink(old / "nvim" / relative), target)
            self.assertFalse((old / "nvim/init.lua").exists())
            self.assertEqual((old / "local.lua").read_text(), "-- personal\n")

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
        storage = self.redirect_storage("yixing", "/mnt/ultracube/earmand")
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
        storage = self.redirect_storage("luogeng", "/media/earmand")
        (storage / ".local").mkdir(parents=True)
        (storage / ".local/lesshst").write_text("history")
        (storage / ".local/starship").write_text("old binary")
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
