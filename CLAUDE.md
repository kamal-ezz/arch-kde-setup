# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A personal post-install / dotfiles repo for a Linux workstation (primary target: Fedora; best-effort for Ubuntu/Debian, Arch, macOS). Everything is plain Bash — no build system, no test suite. The repo is both the installer and the source-of-truth for dotfiles, which are symlinked into `$HOME` from `dotfiles/`.

## Commands

```bash
bash setup.sh                        # run all compatible sections
bash setup.sh --list                 # enumerate sections
bash setup.sh --only kde dotfiles    # run only listed sections
bash setup.sh --skip nvidia snapper  # run all except listed
ENABLE_STRICT_CRYPTO=1 ENABLE_DNS_OVER_TLS=1 bash setup.sh --only security

./snapshot.sh                        # capture current host config back into the repo + commit/push
./sync-gnome.sh                      # re-apply gsettings/extensions from repo to running GNOME session
./sync-pi.sh                         # symlink only ~/.pi/agent/* without running full setup
./setup.sh --only relink             # re-point dotfile symlinks after the repo moves/renames
```

`setup.sh` writes a tee'd log to `~/.unix-setup.log`. Sections are individually idempotent and use `summary_ok` / `summary_skip` / `summary_fail` for end-of-run status.

## Architecture

**`setup.sh`** is one monolithic orchestrator (~2400 lines). It sources the four `lib/*.sh` helpers, parses `--only`/`--skip`, then calls `run_section <slug> <fn>` once per section in fixed order (`main` at the bottom). Section ordering matters — e.g. `repos` must precede `packages`, `shell` precedes `node` (fnm via Oh My Zsh plugin path), and desktop sections run after shared app setup. Plain `bash setup.sh` is intended to be desktop-aware: GNOME-only sections run only on GNOME, KDE-only sections run only on KDE Plasma.

Three gates control section execution:
- `NETWORK_SECTIONS` (in `setup.sh`) — sections short-circuited when offline via `require_internet`.
- `section_supported_on_desktop` (in `setup.sh`) — skips desktop-specific sections before network checks, so KDE/GNOME-only work stays harmless in a plain full run.
- Hidden sections (`steam-components`, `relink`) only run when named explicitly in `--only`.

**`lib/distro.sh`** is the cross-distro abstraction. After `detect_distro` it sets `DISTRO`, `DISTRO_FAMILY`, `PKG_MGR` (`dnf|apt|pacman|brew`) and exposes a uniform API: `pkg_install`, `pkg_install_one`, `pkg_installed`, `pkg_available`, `pkg_swap`, `pm_upgrade`, `add_repo`, `install_local_pkg`, plus `is_linux`/`is_macos`/`require_linux` guards. Section functions should call these rather than branching on `PKG_MGR` directly — only add a `case "$PKG_MGR"` when the operation is genuinely distro-specific (repo configuration, distro-only packages like `akmod-nvidia`). `lib/packages.sh` holds the per-distro package name maps used by `install_packages`.

**`lib/utils.sh`** — logging (`log_info`, `log_warn`, `log_error`, `log_section`), `cmd_exists`, internet probing, backup helpers. **`lib/checks.sh`** — `preflight_checks` (refuses root, refuses missing sudo, etc.). **`lib/colors.sh`** — ANSI codes used by all logging.

**`dotfiles/`** mirrors `$HOME`. `setup_dotfiles` walks this tree and symlinks each file into `$HOME`, backing up any existing real file to `~/.dotfiles_backup/<timestamp>/`. Notable subtrees:
- `.config/Code/User/` — VS Code settings (captured by `snapshot.sh`)
- `.config/zen/` — Zen browser theme + keyboard JSON
- `.config/opencode/opencode.jsonc`
- `.pi/agent/` — Pi assistant config (`settings.json`, `mcp.json`, `agents/`, `APPEND_SYSTEM.md`); sync independently with `sync-pi.sh`
- `.local/share/themes/kamal-tweaks/` — custom GNOME Shell theme (raw copy, not symlinked the same way)
- `.zshrc`, `.p10k.zsh`, `.gitconfig`, `.gitconfig-work`

**Snapshot / sync loop.** Config flows in two directions: `setup.sh` writes the repo into the host once; `snapshot.sh` copies a curated set of live host files back into `dotfiles/` and commits. The dotfile tree is symlinked, so most files stay current automatically — `snapshot.sh` only handles the files that are *copied* rather than symlinked (Zen profile JSON inside a UUID dir, VS Code settings, GNOME theme directory) plus `.gitconfig` variants. When adding a new tracked config, decide: symlink (cheap, edit-in-place) vs. copied snapshot (necessary when the app rewrites the file or lives behind a randomized path).

## Conventions when editing

- New section: add a function, register it in `main()` in the right order, add it to `list_sections`, and to `NETWORK_SECTIONS` if it touches the network. Every section must be re-runnable (check `pkg_installed` / file existence / `grep` config before mutating) and emit one `summary_ok|skip|fail`.
- Prefer the `pkg_*` abstractions over raw `dnf`/`apt`/`pacman`/`brew` invocations.
- Linux-only code paths must start with `require_linux "<label>" || return` so the script stays sourcable on macOS.
- The repo path is not assumed — scripts derive `SCRIPT_DIR` from `${BASH_SOURCE[0]}`. The `relink` section exists specifically to fix dotfile symlinks after the repo directory moves; don't bake absolute paths into committed config.
