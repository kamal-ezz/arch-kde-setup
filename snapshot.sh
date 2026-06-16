#!/usr/bin/env bash
# Capture current OS config state into this repo and push.
# Run from any directory — it always operates on the repo it lives in.
#
# Dotfiles are copied (not symlinked) into $HOME by setup.sh, so this script is
# the only way host edits get back into the repo. Re-run it after any local
# tweak you want to keep.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"

# Copy a single file into the dotfiles tree, skipping if source doesn't exist.
capture() {
    local src="$1" rel="$2"
    local dest="$SCRIPT_DIR/dotfiles/$rel"
    if [[ ! -f "$src" ]]; then
        log_warn "Not found: $src — skipping"
        return
    fi
    mkdir -p "$(dirname "$dest")"
    cp -p "$src" "$dest"
    log_info "Captured $rel"
}

# ─── Shell + Git ──────────────────────────────────────────────────────────────

log_section "Shell + Git"

capture "$HOME/.zshrc"             ".zshrc"
capture "$HOME/.p10k.zsh"          ".p10k.zsh"
capture "$HOME/.gitconfig"         ".gitconfig"
capture "$HOME/.gitconfig-work"    ".gitconfig-work"
capture "$HOME/.gitconfig-imedia24" ".gitconfig-imedia24"

# ─── App configs ──────────────────────────────────────────────────────────────

log_section "App configs"

capture "$HOME/.config/ghostty/config"           ".config/ghostty/config"
capture "$HOME/.config/fontconfig/fonts.conf"    ".config/fontconfig/fonts.conf"
capture "$HOME/.config/fontconfig/conf.d/99-kamal-prefer-inter.conf" ".config/fontconfig/conf.d/99-kamal-prefer-inter.conf"
capture "$HOME/.config/Code/User/settings.json"  ".config/Code/User/settings.json"
capture "$HOME/.config/Code/User/keybindings.json" ".config/Code/User/keybindings.json"
capture "$HOME/.config/opencode/opencode.jsonc"  ".config/opencode/opencode.jsonc"

# ─── Pi agent ─────────────────────────────────────────────────────────────────

log_section "Pi agent"

capture "$HOME/.pi/agent/settings.json"    ".pi/agent/settings.json"
capture "$HOME/.pi/agent/keybindings.json" ".pi/agent/keybindings.json"
capture "$HOME/.pi/agent/mcp.json"         ".pi/agent/mcp.json"

# ─── Steam shortcut fixer ─────────────────────────────────────────────────────

log_section "Steam shortcut fixer"

capture "$HOME/.local/bin/fix-steam-shortcuts"                          ".local/bin/fix-steam-shortcuts"
capture "$HOME/.config/systemd/user/fix-steam-shortcuts.service"        ".config/systemd/user/fix-steam-shortcuts.service"
capture "$HOME/.config/systemd/user/fix-steam-shortcuts.path"           ".config/systemd/user/fix-steam-shortcuts.path"

# ─── Zen browser (lives behind a randomized profile dir) ──────────────────────

log_section "Zen browser"

ZEN_PROFILE_PATH=$(grep '^Path=' "$HOME/.config/zen/profiles.ini" 2>/dev/null | head -1 | cut -d= -f2 || true)

if [[ -z "$ZEN_PROFILE_PATH" ]]; then
    log_warn "No Zen profile found — skipping"
else
    ZEN_PROFILE="$HOME/.config/zen/$ZEN_PROFILE_PATH"
    for f in zen-themes.json zen-keyboard-shortcuts.json; do
        capture "$ZEN_PROFILE/$f" ".config/zen/$f"
    done
fi

# ─── GNOME ────────────────────────────────────────────────────────────────────

log_section "GNOME"

if command -v gsettings &>/dev/null; then
    ENABLED_EXTS=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || true)
    [[ -n "$ENABLED_EXTS" ]] && log_info "Enabled extensions: $ENABLED_EXTS"
    log_info "GNOME settings are managed by sync-gnome.sh — edit that file to change them"
else
    log_warn "gsettings not available — skipping"
fi

KAMAL_TWEAKS_SRC="$HOME/.local/share/themes/kamal-tweaks"
if [[ -d "$KAMAL_TWEAKS_SRC" ]]; then
    mkdir -p "$SCRIPT_DIR/dotfiles/.local/share/themes"
    cp -r "$KAMAL_TWEAKS_SRC" "$SCRIPT_DIR/dotfiles/.local/share/themes/"
    log_info "kamal-tweaks theme captured."
fi

# ─── Commit & push ────────────────────────────────────────────────────────────

log_section "Commit"

cd "$SCRIPT_DIR"

if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    log_info "Nothing changed — repo already up to date"
    exit 0
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
CHANGED=$(git diff --name-only; git ls-files --others --exclude-standard)
SUMMARY=$(echo "$CHANGED" | sed 's|dotfiles/||g; s|\.config/||g' | sort -u | paste -sd ', ')

git add -A
git commit -m "snapshot: $TIMESTAMP — $SUMMARY"
git push

log_info "Snapshot committed and pushed."
