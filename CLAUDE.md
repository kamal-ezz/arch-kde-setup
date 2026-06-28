# CLAUDE.md

This repository is a personal post-install and dotfiles setup for an Arch Linux workstation running KDE Plasma. It is plain Bash, with `setup.sh` as the main orchestrator and `snapshot.sh` as the way to capture local config changes back into the repo.

## Commands

```bash
bash setup.sh                        # run all compatible sections
bash setup.sh --list                 # enumerate sections
bash setup.sh --only kde dotfiles    # run only listed sections
bash setup.sh --skip snapper         # run all except listed
ENABLE_DNS_OVER_TLS=1 bash setup.sh --only security

./snapshot.sh                        # capture current host config back into the repo + commit/push
./sync-kde.sh                        # re-apply KDE Plasma settings from repo to running Plasma session
./sync-pi.sh                         # install only ~/.pi/agent/* without running full setup
```

`setup.sh` writes a tee'd log to `~/.unix-setup.log`. Sections are intended to be idempotent and report their end state through the summary helpers.

## Structure

- `setup.sh`: the main installer. It parses `--only` and `--skip`, then runs sections in a fixed order.
- `lib/distro.sh`: Arch-specific package-manager helpers such as `pkg_install`, `pkg_remove`, `pm_upgrade`, and `bootstrap_aur`.
- `lib/packages.sh`: package groups used by the installer.
- `lib/checks.sh`: preflight checks.
- `lib/utils.sh`: logging, internet checks, GitHub/raw download helpers, and small system probes.
- `dotfiles/`: files copied into `$HOME` by `setup_dotfiles`.

## Dotfiles flow

The repo copies files into the host; it does not symlink them. If a tracked file is changed locally and you want to keep that change in the repo, capture it with `snapshot.sh` before re-running `setup.sh`.

When adding a new tracked config, register it in both:

- `setup_dotfiles` in `setup.sh`
- the capture list in `snapshot.sh`
