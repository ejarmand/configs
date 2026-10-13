"""Exercise automatic Claude and Muse IPv4 setup through the normal installer, offline."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(*args, env, ok=True):
    result = subprocess.run(args, env=env, text=True, capture_output=True)
    if ok:
        assert result.returncode == 0, result.stdout + result.stderr
    else:
        assert result.returncode != 0, result.stdout + result.stderr
    return result


repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="claude-ipv4-check-") as temporary:
    root = Path(temporary)
    source = root / "native.c"
    source.write_text("""#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--version")) { puts("1.0"); return 0; }
    struct addrinfo hints = {0}, *result = NULL;
    if (getenv("LD_PRELOAD") || getenv("AI_IPV4_PREVIOUS_PRELOAD")) return 1;
    if (getaddrinfo("203.0.113.1", "443", &hints, &result)) return 2;
    if (result->ai_family != AF_INET) return 3;
    freeaddrinfo(result);
    /* This lookup succeeds without the shim, so catch a missing preload. */
    if (!getaddrinfo("2001:db8::1", "443", &hints, &result)) {
        freeaddrinfo(result);
        return 5;
    }
    if (argc != 2) return 4;
    puts(argv[1]);
    return 0;
}
""")
    env = {"PATH": os.defpath, "HOME": str(root), "LANG": "C"}
    native = root / "native"
    run("cc", "-Wall", "-Wextra", "-Werror", "-o", str(native), str(source), env=env)
    assert run(str(native), "unwrapped", env=env, ok=False).returncode == 5
    # Stub only network access. Unrelated tools fail without downloading; the
    # ordinary installer must still install Claude and its IPv4 helper in order.
    commands = root / "commands"
    commands.mkdir()
    curl = commands / "curl"
    installer = root / "claude-install.sh"
    installer.write_text(f'#!/bin/sh\nmkdir -p "$HOME/.local/bin"\nln -s "{native}" "$HOME/.local/bin/claude"\n')
    curl.write_text(f'''#!/bin/sh
case "$*" in
  *claude-code-releases/latest) echo 1.0 ;;
  *https://claude.ai/install.sh) cp "{installer}" "$3" ;;
  *) exit 1 ;;
esac
''')
    curl.chmod(0o755)
    # An obsolete workaround-only command must not unexpectedly update all tools.
    assert "Usage:" in run("bash", str(repo / "install-tools.sh"),
                           "--claude-ipv4", env=env, ok=False).stderr
    for mode in ("unaffected", "default", "custom", "storage"):
        case = root / mode
        home = case / "home"
        fixture = case / "repo"
        bin_dir = home / ".local/bin"
        bin_dir.mkdir(parents=True)
        (fixture / ".bashrc.d").mkdir(parents=True)
        for name in ("install-tools.sh", "link.sh", "starship.toml", ".bashrc"):
            shutil.copy2(repo / name, fixture / name)
        shutil.copytree(repo / "network", fixture / "network")
        shutil.copytree(repo / "nvim", fixture / "nvim")
        run("git", "init", "-q", str(fixture), env=env)
        run("git", "-C", str(fixture), "add", "nvim", env=env)
        shutil.copy2(repo / ".bashrc.d/15-tools.sh", fixture / ".bashrc.d")
        storage = case / "storage"
        machine = (repo / ".bashrc.d/05-machines.sh").read_text()
        if mode == "storage":
            machine += f'\nexport XDG_DATA_HOME="{storage}/.local/share"\n'
        (fixture / ".bashrc.d/05-machines.sh").write_text(machine)
        env = {"PATH": str(commands) + ":" + os.defpath, "HOME": str(home), "LANG": "C",
               "HOSTNAME": {"unaffected": "other-host", "default": "pandiero",
                            "custom": "qinto", "storage": "tumba"}[mode]}
        data = home / ".local/share"
        if mode == "custom":
            data = case / "custom-data"
            env["XDG_DATA_HOME"] = str(data)
        elif mode == "storage":
            data = storage / ".local/share"
        if mode != "default":
            (bin_dir / "claude").symlink_to(native)
        # Muse installs itself, so one affected host doesn't have it yet.
        muse = mode != "custom"
        if muse:
            (bin_dir / "muse").write_text(
                '#!/bin/sh\ncase $HTTPS_PROXY in http://127.0.0.1:*) printf "%s\\n" "$*" ;; *) exit 1 ;; esac\n')
            (bin_dir / "muse").chmod(0o755)
        startup = home / ".bashrc"
        startup.write_text("# local shell settings\n")
        (home / ".bashrc.d").mkdir()
        local = home / ".bashrc.d/99-local.sh"
        local.write_text("export LOCAL_SNIPPET=preserved\n")
        (home / ".codex").mkdir()
        config = home / ".codex/config.toml"
        config.write_text('ip_family = "ipv6"\n')
        if mode == "storage":
            # Even an earlier draft's launcher must not create a Codex function.
            (bin_dir / "codex").symlink_to(native)
            (bin_dir / "codex-ipv4").symlink_to(native)
        for _ in range(2):
            result = run("bash", str(fixture / "install-tools.sh"), env=env, ok=False)
            failures = next(line for line in result.stderr.splitlines() if line.startswith("Failed:"))
            assert "claude" not in failures.split(), result.stdout + result.stderr
            assert "muse" not in failures.split(), result.stdout + result.stderr
        assert startup.read_text() == "# local shell settings\n"
        assert os.readlink(bin_dir / "claude") == str(native)
        assert config.read_text() == 'ip_family = "ipv6"\n'
        assert (bin_dir / "codex").exists() == (mode == "storage")
        if mode == "unaffected":
            assert not (bin_dir / "claude-ipv4").exists()
            assert not (bin_dir / "muse-ipv4").exists()
            print("PASS unaffected host: no IPv4 workaround installed")
            continue
        assert (data / "configs/claude-ipv4/ai-ipv4.so").exists()
        assert (data / "configs/muse-ipv4/muse-ipv4-proxy.py").exists()
        launcher = str(bin_dir / "claude-ipv4")
        # Direct GUI launch, with no XDG settings, then a loaded machine shell.
        gui_env = {key: value for key, value in env.items() if key != "XDG_DATA_HOME"}
        assert run(launcher, "argument with spaces", env=gui_env).stdout == "argument with spaces\n"
        if muse:
            assert run(str(bin_dir / "muse-ipv4"), "argument with spaces",
                       env=gui_env).stdout == "argument with spaces\n"
        else:
            assert "Missing" in run(str(bin_dir / "muse-ipv4"), env=gui_env, ok=False).stderr
        run("bash", str(fixture / "link.sh"), env=env)
        assert local.read_text() == "export LOCAL_SNIPPET=preserved\n"
        result = run("bash", "--noprofile", "--norc", "-c",
                     '. "$HOME/.bashrc"; test "$LOCAL_SNIPPET" = preserved || exit 1; '
                     'if declare -F codex >/dev/null; then exit 1; fi; claude "$1"; '
                     'if declare -F muse >/dev/null; then muse "$1"; fi',
                     "check", "argument with spaces", env=env)
        assert result.stdout == "argument with spaces\n" * (2 if muse else 1), result.stdout
        print(f"PASS {mode}: automatic setup, rerun, GUI launch, shared Bash, Codex preserved"
              f"{', Muse proxied' if muse else ', Muse not installed'}")

    # A native updater switching to a script must fail visibly, not skip preload.
    (bin_dir / "claude").unlink()
    (bin_dir / "claude").write_text("#!/bin/sh\nexit 0\n")
    (bin_dir / "claude").chmod(0o755)
    assert "dynamically linked glibc" in run(launcher, env=env, ok=False).stderr
    print("PASS unsupported native binary rejected at launch")
