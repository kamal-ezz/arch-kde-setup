#!/usr/bin/env bash
# Re-apply GNOME gsettings and extension state from this repo to the running session.
# Skips one-time install steps (font/cursor downloads, package installs, sudo operations).
# Run from a live GNOME desktop session (not SSH).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/distro.sh"

detect_desktop

if [[ "$DESKTOP_ENV" != "gnome" ]]; then
    log_error "Not running GNOME (detected: $DESKTOP_ENV). Aborting."
    exit 1
fi

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    log_error "No D-Bus session detected (running via SSH?). Aborting."
    exit 1
fi

# ─── Interface ────────────────────────────────────────────────────────────────

log_section "Interface"

gsettings set org.gnome.desktop.interface color-scheme      'prefer-dark'
gsettings reset org.gnome.desktop.interface gtk-theme 2>/dev/null || true
gsettings set org.gnome.desktop.interface icon-theme        'Papirus-Dark'

CURSOR_THEME=$(ls "$HOME/.local/share/icons/" 2>/dev/null | grep -i "catppuccin.*mocha.*cursor" | head -1 || true)
if [[ -n "$CURSOR_THEME" ]]; then
    gsettings set org.gnome.desktop.interface cursor-theme "$CURSOR_THEME"
    log_info "Cursor theme: $CURSOR_THEME"
else
    log_warn "Catppuccin cursor not found in ~/.local/share/icons — skipping cursor theme"
fi

gsettings set org.gnome.desktop.interface font-name          'Inter 12'
gsettings set org.gnome.desktop.interface document-font-name 'Inter 12'
gsettings set org.gnome.desktop.interface monospace-font-name 'MesloLGS NF 12'
gsettings set org.gnome.desktop.wm.preferences titlebar-font 'Inter Bold 12'

log_info "Interface settings applied."

# ─── Input ────────────────────────────────────────────────────────────────────

log_section "Input"

gsettings set org.gnome.desktop.input-sources sources         "[('xkb', 'us'), ('xkb', 'ara')]"
gsettings set org.gnome.desktop.peripherals.touchpad click-method   'areas'
gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click   true
gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true

log_info "Input settings applied."

# ─── Dock ─────────────────────────────────────────────────────────────────────

log_section "Dock"

gsettings set org.gnome.shell favorite-apps \
    "['org.gnome.Nautilus.desktop', 'google-chrome.desktop', 'com.mitchellh.ghostty.desktop']"

if gsettings list-schemas | grep -qx 'org.gnome.shell.extensions.dash-to-dock'; then
    gsettings set org.gnome.shell.extensions.dash-to-dock transparency-mode      'FIXED'
    gsettings set org.gnome.shell.extensions.dash-to-dock custom-background-color true
    gsettings set org.gnome.shell.extensions.dash-to-dock background-color       '#000000'
    gsettings set org.gnome.shell.extensions.dash-to-dock background-opacity     1.0
    gsettings set org.gnome.shell.extensions.dash-to-dock click-action           'focus-or-previews'
    gsettings set org.gnome.shell.extensions.dash-to-dock scroll-action          'cycle-windows'
    gsettings set org.gnome.shell.extensions.dash-to-dock show-windows-preview   true
    log_info "Dash-to-dock settings applied."
else
    log_warn "Dash-to-dock schema not available — is the extension installed?"
fi

# ─── Extensions ───────────────────────────────────────────────────────────────

log_section "Extensions"

gnome-extensions enable dash-to-dock@micxgx.gmail.com 2>/dev/null && \
    log_info "dash-to-dock enabled." || \
    log_warn "dash-to-dock: enable failed (may need logout/login)"

gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com 2>/dev/null && \
    log_info "appindicatorsupport enabled." || \
    log_warn "appindicatorsupport: enable failed (may need logout/login)"

gnome-extensions enable user-theme@gnome-shell-extensions.gcampax.github.com 2>/dev/null && \
    log_info "user-theme enabled." || true

gnome-extensions enable blur-my-shell@aunetx 2>/dev/null && \
    log_info "blur-my-shell enabled." || \
    log_warn "blur-my-shell: enable failed (may need logout/login)"
dconf write /org/gnome/shell/extensions/blur-my-shell/panel/blur true
dconf write /org/gnome/shell/extensions/blur-my-shell/panel/style-panel 0
dconf write /org/gnome/shell/extensions/blur-my-shell/panel/override-background true
dconf write /org/gnome/shell/extensions/blur-my-shell/panel/override-background-dynamically true
dconf write /org/gnome/shell/extensions/blur-my-shell/panel/customize false
dconf write /org/gnome/shell/extensions/blur-my-shell/panel/color '(0.0, 0.0, 0.0, 0.0)'
log_info "blur-my-shell: panel transparent on desktop, opaque when window is maximized."

gnome-extensions enable rounded-window-corners@fxgn 2>/dev/null && \
    log_info "rounded-window-corners enabled." || \
    log_warn "rounded-window-corners: enable failed (may need logout/login)"

# ─── Default apps ─────────────────────────────────────────────────────────────

log_section "Default apps"

xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null && \
    log_info "Default browser: Google Chrome." || \
    log_warn "Could not set default browser"

for mime in video/mp4 video/x-matroska video/x-msvideo video/webm video/quicktime; do
    xdg-mime default vlc.desktop "$mime"
done
log_info "Video MIME types → VLC."

# ─── Privacy & files ──────────────────────────────────────────────────────────

log_section "Privacy & files"

gsettings set org.gnome.desktop.privacy report-technical-problems false
gsettings set org.gtk.Settings.FileChooser sort-directories-first  true
gsettings set org.gnome.nautilus.preferences sort-directories-first true 2>/dev/null || true

log_info "Privacy and file manager settings applied."

# ─── Night Light ──────────────────────────────────────────────────────────────

log_section "Night Light"

gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled            true
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic false
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-from       20.0
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-to         7.0
gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature         4000

log_info "Night Light: 8pm–7am, 4000K."

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
log_info "GNOME settings synced. Some extension changes require logout/login to take effect."
