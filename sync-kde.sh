#!/usr/bin/env bash
# Re-apply KDE Plasma settings from this repo to the running session.
# Skips one-time install steps (package installs, downloads, sudo operations).
# Run from a live KDE Plasma desktop session (not SSH).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/distro.sh"

detect_desktop

if [[ "$DESKTOP_ENV" != "kde" ]]; then
    log_error "Not running KDE Plasma (detected: $DESKTOP_ENV). Aborting."
    exit 1
fi

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    log_error "No D-Bus session detected (running via SSH?). Aborting."
    exit 1
fi

kde_write() {
    local file="$1"
    local group="$2"
    local key="$3"
    local value="$4"

    if command -v kwriteconfig6 >/dev/null 2>&1; then
        kwriteconfig6 --file "$file" --group "$group" --key "$key" "$value" || {
            log_warn "Could not write $file [$group] $key"
            return 1
        }
    elif command -v kwriteconfig5 >/dev/null 2>&1; then
        kwriteconfig5 --file "$file" --group "$group" --key "$key" "$value" || {
            log_warn "Could not write $file [$group] $key"
            return 1
        }
    else
        log_error "Neither kwriteconfig6 nor kwriteconfig5 found."
        exit 1
    fi
}

kde_delete() {
    local file="$1"
    local group="$2"
    local key="$3"

    if command -v kwriteconfig6 >/dev/null 2>&1; then
        kwriteconfig6 --file "$file" --group "$group" --key "$key" --delete '' || {
            log_warn "Could not delete $file [$group] $key"
            return 1
        }
    elif command -v kwriteconfig5 >/dev/null 2>&1; then
        kwriteconfig5 --file "$file" --group "$group" --key "$key" --delete '' || {
            log_warn "Could not delete $file [$group] $key"
            return 1
        }
    else
        log_error "Neither kwriteconfig6 nor kwriteconfig5 found."
        exit 1
    fi
}

kde_apply_runtime_settings() {
    local color_scheme="$1"
    local cursor_theme="$2"

    if command -v plasma-apply-colorscheme >/dev/null 2>&1; then
        plasma-apply-colorscheme "$color_scheme" >/dev/null 2>&1 || \
            log_warn "Could not apply KDE color scheme live"
    fi

    if [[ -n "$cursor_theme" ]] && command -v plasma-apply-cursortheme >/dev/null 2>&1; then
        plasma-apply-cursortheme "$cursor_theme" >/dev/null 2>&1 || \
            log_warn "Could not apply KDE cursor theme live"
    fi

    if command -v qdbus6 >/dev/null 2>&1; then
        qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
    elif command -v qdbus >/dev/null 2>&1; then
        qdbus org.kde.KWin /KWin reconfigure 2>/dev/null || true
    fi

    log_warn "Some KDE settings apply only after logout/login; not restarting plasmashell automatically."
}

clear_no_color_environment() {
    unset NO_COLOR

    if systemctl --user show-environment 2>/dev/null | grep -q '^NO_COLOR='; then
        systemctl --user unset-environment NO_COLOR 2>/dev/null || true
        log_info "Removed NO_COLOR from the user systemd environment."
    fi

    dbus-update-activation-environment --systemd NO_COLOR 2>/dev/null || true
}

if ! command -v kwriteconfig6 >/dev/null 2>&1 \
   && ! command -v kwriteconfig5 >/dev/null 2>&1; then
    log_error "Neither kwriteconfig6 nor kwriteconfig5 found. Install the KDE config tooling first."
    exit 1
fi

clear_no_color_environment

# ─── Interface ────────────────────────────────────────────────────────────────

log_section "Interface"

local_terminal="konsole"
if command -v ghostty >/dev/null 2>&1; then
    local_terminal="ghostty"
elif ! command -v konsole >/dev/null 2>&1; then
    log_warn "Neither ghostty nor konsole found; leaving KDE terminal setting unchanged"
    local_terminal=""
fi

kde_write kdeglobals General ColorScheme BreezeDark
kde_write kdeglobals Icons Theme Papirus-Dark
kde_write kdeglobals KDE SingleClick false
[[ -n "$local_terminal" ]] && kde_write kdeglobals General TerminalApplication "$local_terminal"

cursor_theme=$(ls "$HOME/.local/share/icons/" 2>/dev/null | grep -i "catppuccin.*mocha.*cursor" | head -1 || true)
if [[ -n "$cursor_theme" ]]; then
    kde_write kdeglobals Mouse cursorTheme "$cursor_theme"
    kde_write kcminputrc Mouse cursorTheme "$cursor_theme"
    log_info "Cursor theme: $cursor_theme"
else
    log_warn "Catppuccin cursor not found in ~/.local/share/icons — skipping cursor theme"
fi

kde_delete kdeglobals General font
kde_delete kdeglobals General menuFont
kde_delete kdeglobals General toolBarFont
kde_delete kdeglobals General smallestReadableFont
kde_delete kdeglobals General fixed
kde_delete kdeglobals WM activeFont

log_info "Interface settings applied."

# ─── Input ────────────────────────────────────────────────────────────────────

log_section "Input"

kde_write kxkbrc Layout Use true
kde_write kxkbrc Layout LayoutList "us,ara"
kde_write kxkbrc Layout VariantList ","

log_info "Input settings applied."

# ─── Dolphin ──────────────────────────────────────────────────────────────────

log_section "Dolphin"

kde_write dolphinrc General BrowseThroughArchives true
kde_write dolphinrc General OpenExternallyCalledFolderInNewTab true
kde_write dolphinrc General RememberOpenedTabs false
kde_write dolphinrc General ShowFullPath true
kde_write dolphinrc General ShowSelectionToggle true
kde_write kdeglobals "KFileDialog Settings" "Sort directories first" true

log_info "Dolphin and file dialog settings applied."

# ─── Default apps ─────────────────────────────────────────────────────────────

log_section "Default apps"

if [[ -f /usr/share/applications/brave-browser.desktop ]] || [[ -f "$HOME/.local/share/applications/brave-browser.desktop" ]]; then
    xdg-settings set default-web-browser brave-browser.desktop 2>/dev/null && \
        log_info "Default browser: Brave." || \
        log_warn "Could not set default browser"
elif [[ -f /usr/share/applications/firefox.desktop ]] || [[ -f "$HOME/.local/share/applications/firefox.desktop" ]]; then
    xdg-settings set default-web-browser firefox.desktop 2>/dev/null && \
        log_info "Default browser: Firefox." || \
        log_warn "Could not set default browser"
fi

for mime in video/mp4 video/x-matroska video/x-msvideo video/webm video/quicktime; do
    xdg-mime default vlc.desktop "$mime"
done
log_info "Video MIME types -> VLC."

# ─── Night Color ──────────────────────────────────────────────────────────────

log_section "Night Color"

kde_write kwinrc NightColor Active true
kde_write kwinrc NightColor Mode Times
kde_write kwinrc NightColor EveningBeginFixed 2000
kde_write kwinrc NightColor MorningBeginFixed 700
kde_write kwinrc NightColor NightTemperature 4000
kde_write kwinrc NightColor TransitionTime 30

log_info "Night Color: 8pm-7am, 4000K."

# ─── Done ─────────────────────────────────────────────────────────────────────

kde_apply_runtime_settings BreezeDark "${cursor_theme:-}"

echo ""
log_info "KDE settings synced. Some changes require logout/login to take effect."
