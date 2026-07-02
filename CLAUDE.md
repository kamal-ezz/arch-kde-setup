# CLAUDE.md

This repository is a personal post-install and dotfiles setup for an Arch Linux workstation running KDE Plasma, structured nix-like: desired state is declared as data in the repo, and tools reconcile the host toward it. Reconciliation is intentionally **additive** — nothing is ever removed automatically.

## Declared state

- `packages/*.list`: package groups, one package per line, `#` comments. A `#!` directive on the first line marks special groups: `#!absent` (should not be installed), `#!candidates` (install the first available), `#!optional` (informational, not drift).
- `dotfiles/`: the tree itself is the manifest. Every file in it is **symlinked** into `$HOME` at the same relative path, so the repo is the single source of truth — editing the file in `$HOME` edits the repo. To track a new config: move it into `dotfiles/`, then run `./cfg apply dotfiles`. No registration lists.
- `services.list`: systemd units expected enabled; `user:` prefix for user units.

## Commands

```bash
./cfg diff                           # show drift between declared state and the host (exit 1 if any)
./cfg apply                          # reconcile: install missing, link dotfiles, enable services
./cfg apply dotfiles                 # reconcile one scope (packages|dotfiles|services)
./cfg unmanaged                      # explicitly installed packages no group declares
./cfg list                           # enumerate declared state

bash setup.sh                        # full bootstrap of a fresh machine (all sections)
bash setup.sh --list                 # enumerate sections
bash setup.sh --only kde dotfiles    # run only listed sections
bash setup.sh --skip snapper         # run all except listed
ENABLE_DNS_OVER_TLS=1 bash setup.sh --only security

./snapshot.sh                        # commit/push; copies in any tracked file not yet symlinked
./sync-kde.sh                        # re-apply KDE Plasma settings from repo to running Plasma session
./sync-pi.sh                         # install only ~/.pi/agent/* without running full setup
```

`setup.sh` writes a tee'd log to `~/.unix-setup.log`. Sections are idempotent and report their end state through the summary helpers. `cfg apply` never removes packages, files, or services; `cfg diff` prints removal hints for `#!absent` groups instead. Before linking over a host file whose content differs from the repo, `cfg apply`/`setup.sh` back it up under `~/.dotfiles_backup/`.

## Structure

- `cfg`: the day-to-day tool — `diff`/`apply`/`unmanaged`/`list` against the declared state.
- `setup.sh`: the full installer for fresh machines. Parses `--only` and `--skip`, then runs sections in a fixed order.
- `lib/distro.sh`: Arch-specific package-manager helpers such as `pkg_install`, `pkg_remove`, `pm_upgrade`, and `bootstrap_aur`.
- `lib/packages.sh`: thin readers over `packages/*.list` (keeps the `pkgs_*` function API).
- `lib/dotfiles.sh`: symlink logic shared by `cfg`, `setup.sh`, and `snapshot.sh` — manifest walk, target resolution (including the Firefox-profile special case), status, and linking.
- `lib/checks.sh`: preflight checks.
- `lib/utils.sh`: logging, internet checks, GitHub/raw download helpers, and small system probes.

## Dotfiles flow

Symlinks, not copies: `~/<path>` → `<repo>/dotfiles/<path>`. Because of that, `snapshot.sh` no longer captures linked files (edits are already in the repo working tree) — it just commits and pushes. Its `capture()` only copies files that are not yet symlinks into the repo, which happens for freshly tracked configs before the first `cfg apply dotfiles`.

Caveat: apps that save config via atomic rename (write temp file + rename over the target) can replace a symlink with a regular file. `cfg diff` reports this as `unlinked-same`/`drifted`; re-link with `cfg apply dotfiles` after capturing any wanted host changes.
