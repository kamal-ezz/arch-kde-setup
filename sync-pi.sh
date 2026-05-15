#!/usr/bin/env bash
# Sync only Pi agent config/extensions from this repo to ~/.pi/agent.
# This avoids re-running the full setup script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$SCRIPT_DIR/dotfiles"
BACKUP_DIR="$HOME/.dotfiles_backup/pi-sync-$(date +%Y%m%d_%H%M%S)"

mapfile -t PI_FILES < <(
  cd "$DOTFILES_DIR" && find .pi/agent -type f | sort
)

for file in "${PI_FILES[@]}"; do
  source="$DOTFILES_DIR/$file"
  target="$HOME/$file"

  if [[ ! -f "$source" ]]; then
    echo "warning: missing $source — skipping" >&2
    continue
  fi

  if [[ -e "$target" && ! -L "$target" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$file")"
    mv "$target" "$BACKUP_DIR/$file"
    echo "backed up $target → $BACKUP_DIR/$file"
  fi

  mkdir -p "$(dirname "$target")"
  ln -sf "$source" "$target"
  echo "synced ~/$file"
done

echo "Pi config/extensions synced. In Pi, run /reload or restart Pi."
