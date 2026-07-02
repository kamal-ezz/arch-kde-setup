#!/usr/bin/env bash
# Capture current OS config state into this repo and push.
# Run from any directory — it always operates on the repo it lives in.
#
# Tracked dotfiles are symlinked into $HOME (see lib/dotfiles.sh), so host
# edits land in the repo directly and capture is a no-op for them — this
# script then just commits and pushes. capture() still copies any file that
# is not yet a symlink into the repo (e.g. on a freshly tracked config).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"

# Copy a single file into the dotfiles tree, skipping if source doesn't exist
# or is already a symlink into the repo.
capture() {
    local src="$1" rel="$2"
    local dest="$SCRIPT_DIR/dotfiles/$rel"
    if [[ ! -f "$src" ]]; then
        log_warn "Not found: $src — skipping"
        return
    fi
    if [[ -L "$src" && "$(readlink -f "$src")" == "$SCRIPT_DIR/dotfiles/"* ]]; then
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

capture "$HOME/.config/brave-flags.conf"           ".config/brave-flags.conf"
capture "$HOME/.config/brave-rice.json"            ".config/brave-rice.json"
capture "$HOME/.config/ghostty/config"           ".config/ghostty/config"
capture "$HOME/.config/fastfetch/config.jsonc"   ".config/fastfetch/config.jsonc"
capture "$HOME/.config/fontconfig/fonts.conf"    ".config/fontconfig/fonts.conf"
capture "$HOME/.config/fontconfig/conf.d/99-kamal-prefer-inter.conf" ".config/fontconfig/conf.d/99-kamal-prefer-inter.conf"
FIREFOX_PROFILE_PATH=$(grep '^Path=' "$HOME/.config/mozilla/firefox/profiles.ini" 2>/dev/null | head -1 | cut -d= -f2 || true)
if [[ -n "$FIREFOX_PROFILE_PATH" ]]; then
    capture "$HOME/.config/mozilla/firefox/$FIREFOX_PROFILE_PATH/user.js" ".config/mozilla/firefox/user.js"
else
    log_warn "No Firefox profile found — skipping Firefox user.js"
fi
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

capture "$HOME/.local/bin/apply-brave-rice"                             ".local/bin/apply-brave-rice"
capture "$HOME/.local/bin/fix-steam-shortcuts"                          ".local/bin/fix-steam-shortcuts"
capture "$HOME/.config/systemd/user/fix-steam-shortcuts.service"        ".config/systemd/user/fix-steam-shortcuts.service"
capture "$HOME/.config/systemd/user/fix-steam-shortcuts.path"           ".config/systemd/user/fix-steam-shortcuts.path"

# ─── GNOME ────────────────────────────────────────────────────────────────────

log_section "GNOME"

if command -v gsettings &>/dev/null; then
    ENABLED_EXTS=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || true)
    [[ -n "$ENABLED_EXTS" ]] && log_info "Enabled extensions: $ENABLED_EXTS"
    log_info "GNOME settings are managed by sync-gnome.sh — edit that file to change them"
else
    log_warn "gsettings not available — skipping"
fi

# ─── KDE ──────────────────────────────────────────────────────────────────────

log_section "KDE"
log_info "KDE Plasma settings are managed by sync-kde.sh — edit that file to change them"

# kamal-tweaks theme files live in dotfiles/ and are symlinked like any other
# tracked file — nothing to capture.

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
