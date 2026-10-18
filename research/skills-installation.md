# Skills linking and dependency installation

Checked on 2026-10-18. Configs setup links the canonical skills and their executable helpers. Following this audit, the tool installer now installs litget from its latest main commit using the existing archive installer, with its executable linked into `~/.local/bin`. Playwright CLI remains outside setup.

## Installation behavior

[setup.sh](../setup.sh) installs its fixed tool list, clones or fast-forwards `ejarmand/skills` at `SKILLS_REPO`, defaulting to `~/projects/skills`, then runs [link.sh](../link.sh). The linker creates a link for each `skills/*/SKILL.md` directory in `~/.agents/skills` and `~/.claude/skills`, and links executable `skills/*/bin/*` helpers into `~/.local/bin`. It backs up conflicting managed paths and preserves unrelated entries.

The upstream [skills installer](https://github.com/ejarmand/skills/blob/main/scripts/link-skills.sh) uses the same default skill destinations. It also removes dangling links owned by that checkout. Configs uses its own linker and does not perform that cleanup, so removed skills can leave dangling links.

## Dependency gap before the change

Before this change, [install-tools.sh](../install-tools.sh) installed Neovim, Codex, opencode, Starship, Pixi, uv, Node through nvm, ripgrep, GitHub CLI, Claude, Muse, and Cursor. Its tool list included neither litget nor playwright-cli. Setup and the linker still do not read the skills requirements inventory or invoke its checker.

The skills [requirements.txt](https://github.com/ejarmand/skills/blob/main/requirements.txt) lists command names, including `litget`, `playwright-cli`, and `jq`. It is not a pip dependency manifest. The [requirements checker](https://github.com/ejarmand/skills/blob/main/scripts/check-requirements.sh) reports command presence, installs nothing, and succeeds even when commands are missing.

[litget installation documentation](https://github.com/ejarmand/litget#requirements-and-installation) requires Node.js 18 or newer and documents a separate global npm installation. Its [package metadata](https://github.com/ejarmand/litget/blob/main/package.json) defines the `litget` executable and no third-party runtime dependencies. Installing Node alone does not install litget.

## Verification on this machine

All 26 canonical skill directories in the local checkout resolve correctly through both `~/.agents/skills` and `~/.claude/skills`.

All 15 existing setup tests passed, including phase ordering and reruns, skill clone/pull/linking with backups, and stopping on diverged skill history. Command:

```sh
python3 tests/check-setup.py
```

Running `~/projects/skills/scripts/check-requirements.sh` reported 19 installed commands and one missing command, `playwright-cli`. `litget` resolves to `~/.nvm/versions/node/v24.22.0/bin/litget`, a link into that Node installation's global npm packages. This existing installation does not establish that configs setup installed it.

An isolated installer check used the actual upstream source archive in temporary directories. Fresh installation, custom data paths, backup of an existing command, running `litget --help`, skipping unchanged downloads, repairing a missing link, lab-server installation, replacing changed commits, and preserving the installed version after download or commit-lookup failures all passed. Shell syntax and diff whitespace checks passed.

The user requested litget installation and is considering dropping Playwright CLI. The implementation therefore adds litget to both normal and lab-server tool lists without adding Playwright CLI. The requirements inventory still includes GNU and systemd tools while configs also supports macOS.
