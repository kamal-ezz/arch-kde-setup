#!/usr/bin/env bash
# Post-install setup script for Arch Linux + KDE Plasma.
# Run as your regular user (not root), from a desktop session.
#
# Usage:
#   bash setup.sh                        # run all compatible sections
#   bash setup.sh --only kde dotfiles    # run only these sections
#   bash setup.sh --skip snapper         # run all except these
#   bash setup.sh --list                 # list available sections
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$HOME/.unix-setup.log"
DOTFILES_DIR="$SCRIPT_DIR/dotfiles"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)"
START_TIME=$(date +%s)

declare -a SUMMARY=()
declare -a ONLY_SECTIONS=()
declare -a SKIP_SECTIONS=()

source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/distro.sh"
source "$SCRIPT_DIR/lib/packages.sh"
source "$SCRIPT_DIR/lib/checks.sh"

summary_ok()   { SUMMARY+=("  ${GREEN}✓${NC}  $*"); }
summary_skip() { SUMMARY+=("  ${YELLOW}→${NC}  $*"); }
summary_fail() { SUMMARY+=("  ${RED}✗${NC}  $*"); }

# ─── Argument parsing ─────────────────────────────────────────────────────────

list_sections() {
    echo "Available sections:"
    echo "  git          Git configuration"
    echo "  pacman       Package manager tuning (parallel downloads, multilib, etc.)"
    echo "  repos        Refresh Arch keyring and bootstrap AUR helper"
    echo "  upgrade      System upgrade"
    echo "  packages     Package installation"
    echo "  ms-fonts     Microsoft fonts"
    echo "  extra-tools  yt-dlp, Neovim, opencode"
    echo "  ghostty      Install Ghostty"
    echo "  flatpak      Flatpak + Flathub + Spotify"
    echo "  steam-components Steam Linux Runtime + Proton + Steamworks Common (run as --only steam-components; needs Steam GUI)"
    echo "  steam-shortcuts  Fix Steam game shortcuts (add StartupWMClass for dock icons)"
    echo "  asus         asusctl/supergfxctl (auto-skips if not ASUS hardware)"
    echo "  fonts        MesloLGS NF, Inter UI font, Catppuccin cursor"
    echo "  shell        Oh My Zsh + Powerlevel10k + plugins"
    echo "  node         fnm + Node.js LTS + npm globals"
    echo "  ssh          SSH key setup"
    echo "  services     Docker + Bluetooth + Firewall"
    echo "  power        power-profiles-daemon (skips on ASUS w/ asusctl)"
    echo "  security     Light security checks; strict hardening is opt-in via env vars"
    echo "  virt         Virtualization (KVM/QEMU)"
    echo "  snapper      Btrfs snapshots (skipped if not Btrfs)"
    echo "  vscode       VS Code extensions + Catppuccin Mocha theme"
    echo "  kde          KDE Plasma-only configuration"
    echo "  dotfiles     Install dotfiles into \$HOME (real files, not symlinks)"
    echo "  shell-default  Set zsh as default shell"
    echo ""
    echo "Examples:"
    echo "  bash setup.sh --only kde dotfiles"
    echo "  bash setup.sh --skip snapper virt"
    echo "  ENABLE_STRICT_CRYPTO=1 ENABLE_DNS_OVER_TLS=1 bash setup.sh --only security"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only)
                shift
                while [[ $# -gt 0 && "${1:-}" != --* ]]; do
                    ONLY_SECTIONS+=("$1"); shift
                done
                ;;
            --skip)
                shift
                while [[ $# -gt 0 && "${1:-}" != --* ]]; do
                    SKIP_SECTIONS+=("$1"); shift
                done
                ;;
            --list)
                list_sections; exit 0
                ;;
            *)
                echo "Unknown argument: $1" >&2
                echo "Use --list to see available sections." >&2
                exit 1
                ;;
        esac
    done
}

should_run() {
    local section="$1"
    # Hidden/manual sections: only run when explicitly requested with --only.
    case "$section" in
        steam-components)
            [[ ${#ONLY_SECTIONS[@]} -eq 0 ]] && return 1
            ;;
    esac
    if [[ ${#ONLY_SECTIONS[@]} -gt 0 ]]; then
        for s in "${ONLY_SECTIONS[@]}"; do
            [[ "$s" == "$section" ]] && return 0
        done
        return 1
    fi
    for s in "${SKIP_SECTIONS[@]}"; do
        [[ "$s" == "$section" ]] && return 1
    done
    return 0
}

section_supported_on_desktop() {
    local section="$1"

    case "$section" in
        kde)
            require_desktop kde || {
                log_warn "Skipping $section: not running KDE Plasma (detected: $DESKTOP_ENV)"
                summary_skip "$section (not on KDE)"
                return 1
            }
            ;;
    esac

    return 0
}

# Sections that require internet access.
NETWORK_SECTIONS=(
    repos upgrade packages ms-fonts extra-tools ghostty flatpak steam-components
    asus fonts shell node ssh services power vscode virt snapper
)

section_needs_internet() {
    local slug="$1" s
    for s in "${NETWORK_SECTIONS[@]}"; do
        [[ "$s" == "$slug" ]] && return 0
    done
    return 1
}

run_section() {
    local slug="$1"
    local fn="$2"
    if ! should_run "$slug"; then
        log_warn "Skipping: $slug"
        return
    fi
    if ! section_supported_on_desktop "$slug"; then
        return
    fi
    if section_needs_internet "$slug" && ! require_internet "$slug"; then
        return
    fi
    "$fn"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

# ─── Section 1: Git Config ────────────────────────────────────────────────────

configure_git() {
    log_section "Section 1: Git Configuration"

    local git_name="kamal-ezz"
    local git_email="ezzarmou.kamal@gmail.com"

    git config --global user.name  "$git_name"
    git config --global user.email "$git_email"
    git config --global init.defaultBranch main
    log_info "Git config ensured for $git_name <$git_email>."
    summary_ok "Git config"
}

# ─── Section 2: Package Manager Configuration ────────────────────────────────

configure_pacman() {
    log_section "Section 2: Package Manager Configuration"

    local PACMAN_CONF="/etc/pacman.conf"
    if ! grep -q '^ParallelDownloads' "$PACMAN_CONF"; then
        sudo sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' "$PACMAN_CONF"
        log_info "pacman ParallelDownloads enabled"
    else
        log_warn "pacman ParallelDownloads already set"
    fi
    if ! grep -qE '^Color' "$PACMAN_CONF"; then
        sudo sed -i 's/^#Color/Color/' "$PACMAN_CONF"
        log_info "pacman Color enabled"
    fi
    if ! grep -qE '^\[multilib\]' "$PACMAN_CONF"; then
        sudo sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/{s/^#//}' "$PACMAN_CONF"
        sudo pacman -Sy --noconfirm
        log_info "pacman multilib enabled"
    fi

    summary_ok "Package manager configuration"
}

# ─── Section 3: Repositories ─────────────────────────────────────────────────

enable_repos_arch() {
    # Most third-party software is either in the official repos or AUR.
    sudo pacman -Sy --needed --noconfirm archlinux-keyring || \
        log_warn "Could not refresh archlinux-keyring; continuing"
    bootstrap_aur
    log_info "AUR helper bootstrapped"
}

enable_repos() {
    log_section "Section 3: Enable Repositories"
    enable_repos_arch
    summary_ok "Repositories"
}

# ─── Section 4: System Upgrade ───────────────────────────────────────────────

system_upgrade() {
    log_section "Section 4: System Upgrade"
    log_info "Running system upgrade with refreshed metadata (this may take a while)..."
    pm_upgrade

    # Firmware updates via fwupd (UEFI, SSD, peripherals)
    if cmd_exists fwupdmgr; then
        log_info "Checking for firmware updates..."
        sudo fwupdmgr refresh --force 2>/dev/null || true
        sudo fwupdmgr update --no-reboot-check 2>/dev/null || \
            log_warn "No firmware updates available or fwupd could not connect"
    else
        log_warn "fwupdmgr not found, skipping firmware updates"
    fi

    summary_ok "System upgrade + firmware"
}

# ─── Section 5: Package Installation ─────────────────────────────────────────

install_docker_engine() {
    local conflicts
    read -ra conflicts <<< "$(pkgs_docker_conflicts)"
    [[ ${#conflicts[@]} -gt 0 ]] && pkg_remove "${conflicts[@]}"
    pkg_install $(pkgs_docker_engine)
}

install_vscode() {
    pkg_install visual-studio-code-bin
}

install_gh_cli() {
    pkg_install github-cli
}

install_wine() {
    pkg_install wine wine-mono wine-gecko
}

install_packages() {
    log_section "Section 5: Package Installation"

    install_docker_engine

    # Java — pick first available LTS
    pkg_install_one $(pkgs_java_candidates)

    pkg_install fuse2

    # Bulk install
    pkg_install $(pkgs_system_tools) \
                $(pkgs_dev) \
                $(pkgs_codecs) \
                $(pkgs_gaming) \
                $(pkgs_steam) \
                $(pkgs_themes) \
                $(pkgs_qt) \
                $(pkgs_fonts_arabic) \
                $(pkgs_bluetooth)

    if require_desktop kde; then
        pkg_install $(pkgs_kde_only)
    fi

    install_vscode
    install_gh_cli
    install_wine
    pkg_install libva-utils intel-media-driver libva-mesa-driver

    summary_ok "Packages"
}

# ─── Section 6: Microsoft Fonts ──────────────────────────────────────────────

install_ms_fonts() {
    log_section "Section 6: Microsoft Fonts"
    pkg_install $(pkgs_ms_fonts)

    log_info "Microsoft fonts installed."
    summary_ok "Microsoft fonts"
}

# ─── Section 7: Extra Tools (yt-dlp, Neovim, opencode) ────────────────────────

install_extra_tools() {
    log_section "Section 7: Extra Tools (yt-dlp, Neovim, opencode)"

    mkdir -p "$HOME/.local/bin"

    if cmd_exists yt-dlp; then
        log_warn "yt-dlp already installed"
        summary_skip "yt-dlp (already installed)"
    else
        log_info "Installing yt-dlp..."
        safe_curl -fLo "$HOME/.local/bin/yt-dlp" \
            https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp
        chmod +x "$HOME/.local/bin/yt-dlp"
        summary_ok "yt-dlp"
    fi

    # Neovim
    if cmd_exists nvim; then
        log_warn "Neovim already installed"
        summary_skip "Neovim (already installed)"
    else
        log_info "Installing Neovim..."
        local NVIM_TMP="/tmp/nvim-linux-x86_64.tar.gz"
        safe_curl -fLo "$NVIM_TMP" \
            https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
        sudo tar -C /opt -xzf "$NVIM_TMP"
        sudo ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim
        rm -f "$NVIM_TMP"
        summary_ok "Neovim"
    fi

    if cmd_exists opencode; then
        log_warn "opencode already installed"
        summary_skip "opencode (already installed)"
    else
        log_info "Installing opencode via the official install script..."
        local OC_SCRIPT="/tmp/opencode-install.sh"
        local oc_installed=0
        if safe_curl -fsSL https://opencode.ai/install -o "$OC_SCRIPT"; then
            bash "$OC_SCRIPT" && oc_installed=1
            rm -f "$OC_SCRIPT"
        fi
        if [[ "$oc_installed" -ne 1 ]]; then
            # Fallback: GitHub release tarball. The install script downloads
            # the same binary.
            log_warn "opencode install script unavailable; falling back to GitHub release binary"
            local oc_asset
            case "$(uname -m)" in
                x86_64|amd64)  oc_asset="opencode-linux-x64.tar.gz" ;;
                aarch64|arm64) oc_asset="opencode-linux-arm64.tar.gz" ;;
                *) log_warn "No opencode release binary for $(uname -m)"; oc_asset="" ;;
            esac
            if [[ -n "$oc_asset" ]]; then
                local OC_TAR="/tmp/$oc_asset"
                if safe_curl -fLo "$OC_TAR" \
                        "https://github.com/anomalyco/opencode/releases/latest/download/$oc_asset"; then
                    tar -xzf "$OC_TAR" -C "$HOME/.local/bin" opencode 2>/dev/null \
                        || tar -xzf "$OC_TAR" -C "$HOME/.local/bin"
                    chmod +x "$HOME/.local/bin/opencode" 2>/dev/null || true
                    rm -f "$OC_TAR"
                    oc_installed=1
                fi
            fi
        fi
        if [[ "$oc_installed" -eq 1 ]]; then
            summary_ok "opencode"
        else
            log_warn "Could not install opencode (script + release binary both failed)"
            summary_fail "opencode"
        fi
    fi

}

# ─── Section 8: Ghostty ───────────────────────────────────────────────────────

install_ghostty() {
    log_section "Section 8: Ghostty"

    if cmd_exists ghostty; then
        log_warn "Ghostty already installed, skipping"
        summary_skip "Ghostty (already installed)"
        return
    fi

    log_info "Installing Ghostty from Arch repositories..."
    pkg_install ghostty
    if cmd_exists ghostty; then
        summary_ok "Ghostty (installed from Arch repos)"
    else
        summary_fail "Ghostty"
    fi
}

# ─── Section 9: Flatpak + Flathub ────────────────────────────────────────────

setup_flatpak() {
    log_section "Section 9: Flatpak + Flathub"

    pkg_install flatpak
    require_desktop kde && pkg_install flatpak-kcm xdg-desktop-portal-kde

    if flatpak remotes 2>/dev/null | grep -q flathub; then
        log_warn "Flathub already configured"
        summary_skip "Flathub (already configured)"
    else
        log_info "Adding Flathub remote..."
        flatpak remote-add --if-not-exists flathub \
            https://flathub.org/repo/flathub.flatpakrepo
        summary_ok "Flathub"
    fi

    if flatpak list 2>/dev/null | grep -q "com.spotify.Client"; then
        log_warn "Spotify already installed"
    else
        log_info "Installing Spotify..."
        flatpak install -y flathub com.spotify.Client
        summary_ok "Spotify"
    fi

}

# ─── Section 11: Steam Runtime Components ────────────────────────────────────

install_steam_components() {
    log_section "Section 10: Steam Runtime Components"

    if ! cmd_exists steam; then
        log_warn "Steam is not installed; install packages first or run: bash setup.sh --only packages steam-components"
        summary_fail "Steam runtime components (Steam missing)"
        return 0
    fi

    if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log_warn "No desktop session detected; Steam component installs need the Steam GUI. Skipping."
        summary_skip "Steam runtime components (no GUI session)"
        return 0
    fi

    # Steam dependency/tool app IDs. Override STEAM_LINUX_RUNTIME_4_APPID if Valve changes it.
    local components=(
        "${STEAM_LINUX_RUNTIME_4_APPID:-3658110}|Steam Linux Runtime 4.0"
        "1493710|Proton Experimental"
        "228980|Steamworks Common Redistributables"
    )

    log_info "Requesting Steam to install/update required compatibility tools..."
    log_warn "Steam may open and prompt you to sign in; downloads continue in the Steam client."

    # Launch Steam once and let it come up before we hand it deep-link URLs.
    # The previous version queued three URLs in a 3-second loop, which races
    # Steam's startup and silently drops the URLs that arrive too early.
    if ! pgrep -x steam >/dev/null 2>&1; then
        nohup steam >/dev/null 2>&1 &
        log_info "Waiting for Steam to start..."
        local waited=0
        while ! pgrep -x steam >/dev/null 2>&1; do
            sleep 1
            waited=$((waited + 1))
            [[ "$waited" -ge 30 ]] && break
        done
        # Steam's URL handler needs a few seconds after the main process appears.
        sleep 8
    fi

    local entry appid name
    for entry in "${components[@]}"; do
        appid="${entry%%|*}"
        name="${entry#*|}"
        log_info "Queueing $name (app $appid)..."
        steam "steam://install/${appid}" >/dev/null 2>&1 || \
            log_warn "Could not queue $name; queue it manually from the Steam client"
        sleep 5
    done

    summary_ok "Steam runtime components queued"
}

# ─── Section 10b: Steam Shortcut WMClass Fixes ───────────────────────────────

fix_steam_shortcuts() {
    log_section "Section 10b: Steam Shortcut WMClass Fixes"

    local script="$HOME/.local/bin/fix-steam-shortcuts"
    if [[ ! -x "$script" ]]; then
        log_warn "$script not installed; run --only dotfiles first"
        summary_skip "Steam shortcuts (script missing)"
        return
    fi

    # Apply immediately to any existing shortcuts
    "$script" || log_warn "fix-steam-shortcuts exited non-zero"

    # Enable the path watcher so future Steam shortcuts get fixed automatically
    if is_linux; then
        if systemctl --user enable --now fix-steam-shortcuts.path 2>/dev/null; then
            log_info "Enabled fix-steam-shortcuts.path (auto-fixes new Steam shortcuts)"
        else
            log_warn "Could not enable fix-steam-shortcuts.path (no user session?)"
        fi
    fi

    summary_ok "Steam shortcuts (applied + path watcher enabled)"
}

# ─── Section 11: ASUS Linux Tools ────────────────────────────────────────────

install_asus_tools() {
    log_section "Section 11: ASUS Linux Tools"

    if ! has_asus_hardware; then
        log_warn "No ASUS hardware detected, skipping asusctl"
        summary_skip "ASUS tools (not ASUS hardware)"
        return
    fi

    if pkg_installed asusctl && pkg_installed supergfxctl; then
        log_warn "ASUS tools already installed"
    else
        log_info "Installing asusctl and supergfxctl from AUR..."
        pkg_install asusctl supergfxctl
    fi

    # Best-effort, non-blocking configuration. Each command is timeout-limited
    # and failure is logged but never aborts the setup.
    timeout 15s sudo systemctl enable --now asusd 2>/dev/null || \
        log_warn "Could not enable asusd service"
    timeout 15s sudo systemctl enable --now supergfxd 2>/dev/null || \
        log_warn "Could not enable supergfxd service"

    if cmd_exists asusctl; then
        timeout 10s asusctl profile -P Quiet 2>/dev/null || \
            log_warn "Could not set ASUS profile to Quiet/power-saver"
        timeout 10s asusctl -c 80 2>/dev/null || \
            log_warn "Could not set ASUS battery charge limit to 80%"
    else
        log_warn "asusctl command not found after install; skipping ASUS profile config"
    fi

    log_info "Leaving ASUS GPU mode unchanged; change it manually with supergfxctl if needed"
    summary_ok "ASUS tools"
}

# ─── Section 12: Fonts / Shared Desktop Assets ───────────────────────────────

install_inter_font() {
    if fc-match Inter 2>/dev/null | grep -qi "^inter"; then
        log_warn "Inter font already installed"
        return 0
    fi

    log_info "Installing Inter font..."
    local INTER_ZIP="/tmp/inter.zip"
    local INTER_URL
    INTER_URL=$(safe_curl -fsSL https://api.github.com/repos/rsms/inter/releases/latest \
        | grep -o '"browser_download_url": *"[^"]*Inter-[^"]*\.zip"' \
        | grep -o 'https://[^"]*' | head -1 || true)
    if [[ -z "$INTER_URL" ]]; then
        log_warn "Could not resolve Inter font URL, skipping"
        return 0
    fi

    if safe_curl -fLo "$INTER_ZIP" "$INTER_URL"; then
        mkdir -p "$HOME/.local/share/fonts/Inter"
        unzip -j -q "$INTER_ZIP" "*/extras/otf/*.otf" \
            -d "$HOME/.local/share/fonts/Inter" 2>/dev/null || \
            unzip -q "$INTER_ZIP" -d "$HOME/.local/share/fonts/Inter"
        fc-cache -f "$HOME/.local/share/fonts"
        log_info "Inter font installed."
    else
        log_warn "Could not download Inter font, skipping"
    fi
    rm -f "$INTER_ZIP"
}

install_catppuccin_cursor() {
    if ls "$HOME/.local/share/icons/" 2>/dev/null | grep -qi "catppuccin.*mocha.*cursor"; then
        log_warn "Catppuccin cursor already installed"
        return 0
    fi

    log_info "Installing Catppuccin cursor..."
    local CURSOR_ZIP="/tmp/catppuccin-cursors.zip"
    local CURSOR_URL
    CURSOR_URL=$(safe_curl -fsSL https://api.github.com/repos/catppuccin/cursors/releases/latest \
        | grep -oi '"browser_download_url": *"[^"]*mocha[^"]*dark[^"]*\.zip"' \
        | grep -o 'https://[^"]*' | head -1 || true)
    if [[ -z "$CURSOR_URL" ]]; then
        log_warn "Could not resolve Catppuccin cursor URL, skipping"
        return 0
    fi

    if safe_curl -fLo "$CURSOR_ZIP" "$CURSOR_URL"; then
        mkdir -p "$HOME/.local/share/icons"
        unzip -q "$CURSOR_ZIP" -d "$HOME/.local/share/icons/"
        log_info "Catppuccin cursor installed."
    else
        log_warn "Could not download Catppuccin cursor, skipping"
    fi
    rm -f "$CURSOR_ZIP"
}

install_fonts() {
    log_section "Section 12: Fonts / Shared Desktop Assets"

    local FONT_DIR="$HOME/.local/share/fonts"
    local FONT_CHECK="$FONT_DIR/MesloLGS NF Regular.ttf"

    mkdir -p "$FONT_DIR"
    if [[ -f "$FONT_CHECK" ]]; then
        log_warn "MesloLGS NF already installed"
    else
        local FONTS=(
            "MesloLGS NF Regular.ttf"
            "MesloLGS NF Bold.ttf"
            "MesloLGS NF Italic.ttf"
            "MesloLGS NF Bold Italic.ttf"
        )

        for font in "${FONTS[@]}"; do
            log_info "Downloading $font..."
            gh_raw_fetch romkatv/powerlevel10k-media master "$font" "$FONT_DIR/$font" \
                || log_warn "Could not download $font"
        done

        fc-cache -fv "$FONT_DIR"
    fi

    install_inter_font
    install_catppuccin_cursor
    summary_ok "Fonts / shared desktop assets"
}

# ─── Section 12: Oh My Zsh + Powerlevel10k + Plugins ─────────────────────────

install_shell_extras() {
    log_section "Section 12: Oh My Zsh + Powerlevel10k + Plugins"

    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        log_warn "Oh My Zsh already installed"
    else
        log_info "Installing Oh My Zsh..."
        local OMZ_SCRIPT="/tmp/omz-install.sh"
        if gh_raw_fetch ohmyzsh/ohmyzsh master tools/install.sh "$OMZ_SCRIPT"; then
            RUNZSH=no CHSH=no bash "$OMZ_SCRIPT"
            rm -f "$OMZ_SCRIPT"
        else
            # Fallback: clone the repo directly. Git uses plain HTTPS and goes
            # through ISPs that block raw.githubusercontent.com / jsDelivr.
            log_warn "Installer fetch failed; falling back to git clone"
            if git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"; then
                [[ -f "$HOME/.zshrc" ]] || \
                    cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$HOME/.zshrc"
            else
                log_warn "Could not install Oh My Zsh (installer + git clone both failed)"
            fi
        fi
    fi

    local ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        log_warn "Oh My Zsh is not installed; skipping Powerlevel10k and plugin setup"
        summary_skip "Oh My Zsh + Powerlevel10k + plugins (Oh My Zsh install failed)"
        return
    fi

    mkdir -p "$ZSH_CUSTOM/themes" "$ZSH_CUSTOM/plugins"

    if [[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]]; then
        log_info "Installing Powerlevel10k..."
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
            "$ZSH_CUSTOM/themes/powerlevel10k"
    else
        log_warn "Powerlevel10k already installed"
    fi

    local PLUGINS=(
        "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions"
        "zsh-completions|https://github.com/zsh-users/zsh-completions"
        "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting"
    )

    for entry in "${PLUGINS[@]}"; do
        local plugin="${entry%%|*}"
        local url="${entry#*|}"
        if [[ ! -d "$ZSH_CUSTOM/plugins/$plugin" ]]; then
            log_info "Installing plugin: $plugin..."
            git clone --depth=1 "$url" "$ZSH_CUSTOM/plugins/$plugin"
        else
            log_warn "Plugin $plugin already installed"
        fi
    done

    summary_ok "Oh My Zsh + Powerlevel10k + plugins"
}

# ─── Section 13: fnm + Node.js LTS + global packages ─────────────────────────

install_node() {
    log_section "Section 13: fnm + Node.js LTS"

    mkdir -p "$HOME/.local/bin"

    if cmd_exists fnm; then
        log_warn "fnm already installed"
    else
        log_info "Installing fnm..."
        local FNM_SCRIPT="/tmp/fnm-install.sh"
        local fnm_installed=0
        if safe_curl -fsSL https://fnm.vercel.app/install -o "$FNM_SCRIPT"; then
            bash "$FNM_SCRIPT" --install-dir "$HOME/.local/bin" --skip-shell \
                && fnm_installed=1
            rm -f "$FNM_SCRIPT"
        fi
        if [[ "$fnm_installed" -ne 1 ]]; then
            # Fallback: pull the release binary straight from GitHub. The
            # install script does ~exactly this; bypassing it avoids the
            # fnm.vercel.app hop if it's flaky or blocked.
            log_warn "fnm install script unavailable; falling back to GitHub release binary"
            local fnm_asset
            case "$(uname -m)" in
                x86_64|amd64)  fnm_asset="fnm-linux.zip" ;;
                aarch64|arm64) fnm_asset="fnm-arm64.zip" ;;
                armv7l)        fnm_asset="fnm-arm32.zip" ;;
                *) log_warn "No fnm release binary for $(uname -m)"; fnm_asset="" ;;
            esac
            if [[ -n "$fnm_asset" ]]; then
                local FNM_ZIP="/tmp/$fnm_asset"
                if safe_curl -fLo "$FNM_ZIP" \
                        "https://github.com/Schniz/fnm/releases/latest/download/$fnm_asset"; then
                    unzip -o -q "$FNM_ZIP" -d /tmp/fnm-extract
                    install -m 0755 /tmp/fnm-extract/fnm "$HOME/.local/bin/fnm"
                    rm -rf "$FNM_ZIP" /tmp/fnm-extract
                else
                    log_warn "Could not download fnm release binary"
                fi
            fi
        fi
    fi

    local FNM_BIN
    FNM_BIN="$(command -v fnm || echo "$HOME/.local/bin/fnm")"

    if [[ ! -x "$FNM_BIN" ]]; then
        log_warn "fnm binary not found after install — skipping Node.js setup"
        summary_fail "fnm + Node.js"
        return 0
    fi

    log_info "Installing Node.js LTS via fnm..."
    "$FNM_BIN" install --lts
    "$FNM_BIN" default lts-latest

    local NPM_BIN
    NPM_BIN="$("$FNM_BIN" exec --using=lts-latest which npm 2>/dev/null || true)"

    if [[ -z "$NPM_BIN" ]]; then
        log_warn "npm not found via fnm — skipping global npm packages"
        summary_fail "npm global packages"
        return 0
    fi

    # pkg → CLI binary used to detect a working install installed elsewhere
    # (e.g. pi-coding-agent ships its own pi-node prefix containing pnpm,
    # which `npm list -g` against fnm's prefix would miss).
    local NPM_GLOBALS=(
        "@openai/codex|codex"
        "@anthropic-ai/claude-code|claude"
        "@earendil-works/pi-coding-agent|pi"
        "pnpm|pnpm"
    )

    for entry in "${NPM_GLOBALS[@]}"; do
        local pkg="${entry%%|*}"
        local bin="${entry#*|}"
        if "$NPM_BIN" list -g "$pkg" &>/dev/null || cmd_exists "$bin"; then
            log_warn "$pkg already installed"
        else
            log_info "Installing $pkg..."
            "$NPM_BIN" install -g "$pkg" || \
                log_warn "Could not install $pkg — continuing"
        fi
    done

    if cmd_exists bun; then
        log_warn "bun already installed"
    else
        log_info "Installing bun..."
        local BUN_SCRIPT="/tmp/bun-install.sh"
        local bun_installed=0
        if safe_curl -fsSL https://bun.sh/install -o "$BUN_SCRIPT"; then
            bash "$BUN_SCRIPT" && bun_installed=1
            rm -f "$BUN_SCRIPT"
        fi
        if [[ "$bun_installed" -ne 1 ]]; then
            # Fallback: install via npm (already provisioned above). Vendor-
            # supported method per https://bun.sh/docs/installation.
            log_warn "bun install script unavailable; falling back to npm install -g bun"
            "$NPM_BIN" install -g bun || log_warn "Could not install bun — continuing"
        fi
    fi

    summary_ok "fnm + Node.js LTS + global packages"
}

# ─── Section 14: SSH Key Setup ────────────────────────────────────────────────

setup_ssh() {
    log_section "Section 14: SSH Key Setup"

    local SSH_KEY="$HOME/.ssh/id_ed25519"

    if [[ -f "$SSH_KEY" ]]; then
        log_warn "SSH key already exists at $SSH_KEY, skipping"
        summary_skip "SSH key (already exists)"
        return
    fi

    local EMAIL
    EMAIL="$(git config --global user.email 2>/dev/null || echo "")"
    if [[ -z "$EMAIL" ]]; then
        read -rp "Email for SSH key: " EMAIL
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    # Prompt for a passphrase (empty input keeps the legacy behaviour).
    ssh-keygen -t ed25519 -C "$EMAIL" -f "$SSH_KEY"
    eval "$(ssh-agent -s)"
    ssh-add "$SSH_KEY"

    # GitHub's published host keys (https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints).
    # Verify whatever ssh-keyscan returns against these fingerprints before
    # trusting it, so a first-run MITM can't seed a bogus known_hosts entry.
    local expected_fps=(
        "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
        "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"
        "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"
    )
    local scanned
    scanned="$(ssh-keyscan -t ed25519,rsa,ecdsa github.com 2>/dev/null || true)"
    local scanned_fps
    scanned_fps="$(printf '%s\n' "$scanned" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
    local fp matched=0
    if [[ -n "$scanned_fps" ]]; then
        for fp in "${expected_fps[@]}"; do
            if grep -qxF "$fp" <<< "$scanned_fps"; then matched=1; break; fi
        done
    fi
    if [[ "$matched" == "1" ]]; then
        printf '%s\n' "$scanned" >> "$HOME/.ssh/known_hosts"
        log_info "Added verified github.com host keys to known_hosts"
    else
        log_warn "Could not verify github.com host keys against expected fingerprints — not adding to known_hosts"
    fi

    echo ""
    log_info "SSH key generated. Add this public key to GitHub:"
    echo ""
    cat "${SSH_KEY}.pub"
    echo ""
    log_warn "Go to: https://github.com/settings/ssh/new"
    read -rp "Press Enter once you've added the key to GitHub..."
    ssh -T git@github.com 2>&1 || true
    summary_ok "SSH key"
}

# ─── Section 15: Services (Docker, Bluetooth, Firewall) ──────────────────────

setup_services() {
    log_section "Section 15: Services (Docker, Bluetooth, Firewall)"

    log_info "Enabling Docker service..."
    sudo systemctl enable --now docker || log_warn "Could not enable docker service"
    sudo systemctl enable --now containerd 2>/dev/null || true

    if user_in_group docker; then
        log_warn "User $USER already in docker group"
    else
        sudo usermod -aG docker "$USER"
        log_warn "Docker group membership active after reboot."
    fi

    # Bluetooth
    if systemctl is-active --quiet bluetooth; then
        log_warn "Bluetooth service already running"
    else
        log_info "Enabling Bluetooth service..."
        sudo systemctl enable --now bluetooth
    fi

    # Firewall
    log_info "Configuring firewall..."
    pkg_install $(pkgs_firewall)
    sudo systemctl enable --now firewalld
    sudo firewall-cmd --set-default-zone=public
    sudo firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
    log_warn "Inbound HTTP/HTTPS are not opened by default; add them manually if this machine hosts web services."

    if ! sudo firewall-cmd --permanent --list-rich-rules 2>/dev/null | grep -q "ssh.*limit"; then
        sudo firewall-cmd --permanent \
            --add-rich-rule='rule service name="ssh" limit value="6/m" accept'
        log_info "SSH rate limiting enabled."
    else
        log_warn "SSH rate limiting already configured"
    fi
    sudo firewall-cmd --reload

    # Boot time: disable NetworkManager-wait-online (saves ~15-20s on desktops)
    if systemctl is-enabled NetworkManager-wait-online.service &>/dev/null; then
        sudo systemctl disable NetworkManager-wait-online.service
        log_info "Disabled NetworkManager-wait-online (faster boot)"
    else
        log_warn "NetworkManager-wait-online already disabled"
    fi

    # SSD TRIM
    if systemctl is-enabled fstrim.timer &>/dev/null; then
        log_warn "fstrim.timer already enabled"
    else
        log_info "Enabling fstrim.timer..."
        sudo systemctl enable --now fstrim.timer
    fi

    # zram: use zstd compression (better ratio than default lzo-rle)
    local ZRAM_CONF="/etc/systemd/zram-generator.conf.d/zstd.conf"
    if [[ -f "$ZRAM_CONF" ]]; then
        log_warn "zram zstd already configured"
    else
        sudo mkdir -p /etc/systemd/zram-generator.conf.d
        printf '[zram0]\ncompression-algorithm = zstd\n' | \
            sudo tee "$ZRAM_CONF" > /dev/null
        log_info "zram compression set to zstd (takes effect after reboot)"
    fi

    summary_ok "Services"
}

# ─── Section 15b: Power Profiles ─────────────────────────────────────────────
#
# Installs power-profiles-daemon so KDE's battery applet exposes the
# Power Save / Balanced / Performance switch and `powerprofilesctl` works.
# Override the default profile with POWER_PROFILE=balanced (or performance).

setup_power_profiles() {
    log_section "Section 15b: Power Profiles"

    # On ASUS laptops asusd owns the platform profile; power-profiles-daemon
    # fights it for the same sysfs knob. Let the asus section handle profiles.
    if has_asus_hardware && pkg_installed asusctl; then
        log_warn "ASUS hardware with asusctl detected; asusd manages power profiles."
        summary_skip "Power profiles (managed by asusctl)"
        return
    fi

    # power-profiles-daemon conflicts with other power managers over the same
    # platform-profile/CPU knobs. Don't fight an already-installed one.
    local conflict
    for conflict in tlp tuned; do
        if pkg_installed "$conflict"; then
            log_warn "$conflict is installed; it conflicts with power-profiles-daemon over the same power knobs."
            log_warn "  Remove it first ('sudo pacman -Rns $conflict') then re-run: bash setup.sh --only power"
            summary_skip "Power profiles (conflicts with $conflict)"
            return
        fi
    done

    pkg_install $(pkgs_power)

    if sudo systemctl enable --now power-profiles-daemon 2>/dev/null; then
        log_info "power-profiles-daemon enabled"
    else
        log_warn "Could not enable power-profiles-daemon service"
    fi

    if cmd_exists powerprofilesctl; then
        local profile="${POWER_PROFILE:-power-saver}"
        if powerprofilesctl set "$profile" 2>/dev/null; then
            log_info "Power profile set to $profile"
        else
            log_warn "Could not set power profile to '$profile' (unsupported on this hardware?)"
        fi
    else
        log_warn "powerprofilesctl not found after install; skipping default profile"
    fi

    summary_ok "Power profiles"
}

# ─── Section 16: Security Checks / Optional Hardening ───────────────────────
#
# Defaults are intentionally conservative to avoid breaking VPNs, corporate
# networks, captive portals, legacy SSH hosts, or custom SELinux workflows.
#
# Optional strict mode examples:
#   ENABLE_STRICT_CRYPTO=1 bash setup.sh --only security
#   ENABLE_DNS_OVER_TLS=1 bash setup.sh --only security
#   FORCE_SELINUX_ENFORCING=1 bash setup.sh --only security
#
# Revert crypto policy:  sudo update-crypto-policies --set DEFAULT
# Revert DNS over TLS:   sudo rm /etc/systemd/resolved.conf.d/99-dns-over-tls.conf && sudo systemctl restart systemd-resolved

setup_security() {
    log_section "Section 16: Security Checks / Optional Hardening"

    if cmd_exists update-crypto-policies; then
        local current_crypto_policy
        current_crypto_policy="$(update-crypto-policies --show 2>/dev/null || true)"
        if [[ "${ENABLE_STRICT_CRYPTO:-0}" == "1" ]]; then
            if [[ "$current_crypto_policy" == *"NO-SHA1"* ]]; then
                log_warn "Crypto policy already includes NO-SHA1"
            else
                sudo update-crypto-policies --set DEFAULT:NO-SHA1
                log_info "Crypto policy set to DEFAULT:NO-SHA1"
                log_warn "  Revert: sudo update-crypto-policies --set DEFAULT"
            fi
        else
            log_info "Crypto policy: ${current_crypto_policy:-unknown}"
            log_warn "Strict crypto skipped. Set ENABLE_STRICT_CRYPTO=1 to disable SHA-1 system-wide."
        fi
    else
        log_warn "update-crypto-policies not available — skipping crypto policy"
    fi

    local DNS_CONF="/etc/systemd/resolved.conf.d/99-dns-over-tls.conf"
    if [[ "${ENABLE_DNS_OVER_TLS:-0}" == "1" ]]; then
        if [[ -f "$DNS_CONF" ]]; then
            log_warn "DNS over TLS already configured"
        else
            sudo mkdir -p /etc/systemd/resolved.conf.d
            sudo tee "$DNS_CONF" > /dev/null <<'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
DNSOverTLS=yes
DNSSEC=yes
EOF
            sudo systemctl restart systemd-resolved
            log_info "DNS over TLS configured (Cloudflare + Quad9)"
            log_warn "  Revert: sudo rm $DNS_CONF && sudo systemctl restart systemd-resolved"
        fi
    else
        log_warn "DNS over TLS skipped. Set ENABLE_DNS_OVER_TLS=1 to enable it."
    fi

    if cmd_exists getenforce; then
        local selinux_state
        selinux_state="$(getenforce 2>/dev/null || echo unknown)"
        if echo "$selinux_state" | grep -qi "enforcing"; then
            log_info "SELinux: enforcing"
        elif [[ "${FORCE_SELINUX_ENFORCING:-0}" == "1" ]]; then
            log_warn "SELinux is $selinux_state — setting enforcing because FORCE_SELINUX_ENFORCING=1"
            sudo setenforce 1 2>/dev/null || true
            sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
            log_info "SELinux set to enforcing"
        else
            log_warn "SELinux is $selinux_state. Set FORCE_SELINUX_ENFORCING=1 to enforce it."
        fi
    elif cmd_exists aa-status; then
        if sudo aa-status --enabled 2>/dev/null; then
            log_info "AppArmor: enabled"
        else
            log_warn "AppArmor not enabled — install/enable manually if desired"
        fi
    else
        log_warn "No MAC framework detected (no SELinux or AppArmor)"
    fi

    summary_ok "Security checks / optional hardening"
}

# ─── Section 17: Virtualization ──────────────────────────────────────────────

setup_virtualization() {
    log_section "Section 17: Virtualization"

    log_info "Installing virtualization packages..."
    pkg_install $(pkgs_virt)

    if systemctl list-unit-files virtqemud.service &>/dev/null; then
        sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket 2>/dev/null \
            || log_warn "Could not enable virtqemud sockets"
    else
        sudo systemctl enable --now libvirtd || log_warn "Could not enable libvirtd"
    fi

    for group in libvirt kvm; do
        if user_in_group "$group"; then
            log_warn "User already in $group group"
        else
            sudo usermod -aG "$group" "$USER"
            log_info "Added $USER to $group group"
        fi
    done

    summary_ok "Virtualization"
}

# ─── Section 18: Snapper (Btrfs snapshots) ───────────────────────────────────

setup_snapper() {
    log_section "Section 18: Snapper (Btrfs Snapshots)"

    if ! findmnt -n -o FSTYPE / 2>/dev/null | grep -q btrfs; then
        log_warn "Root filesystem is not Btrfs — skipping Snapper setup."
        summary_skip "Snapper (not Btrfs)"
        return
    fi

    pkg_install $(pkgs_snapper)

    # Root config
    if ! sudo snapper list-configs 2>/dev/null | grep -q "^root"; then
        log_info "Creating Snapper root config..."
        sudo snapper -c root create-config /
        sudo snapper -c root set-config \
            TIMELINE_LIMIT_HOURLY=1 TIMELINE_LIMIT_DAILY=2 \
            TIMELINE_LIMIT_WEEKLY=0 TIMELINE_LIMIT_MONTHLY=0 \
            TIMELINE_LIMIT_YEARLY=0
    else
        log_warn "Snapper root config already exists"
    fi

    # Home config
    if ! sudo snapper list-configs 2>/dev/null | grep -q "^home"; then
        log_info "Creating Snapper home config..."
        sudo snapper -c home create-config /home
        sudo snapper -c home set-config \
            TIMELINE_LIMIT_HOURLY=2 TIMELINE_LIMIT_DAILY=3 \
            TIMELINE_LIMIT_WEEKLY=0 TIMELINE_LIMIT_MONTHLY=1 \
            TIMELINE_LIMIT_YEARLY=0
    else
        log_warn "Snapper home config already exists"
    fi

    sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer

    # Take initial snapshot so there's something to roll back to immediately
    if ! sudo snapper -c root list 2>/dev/null | grep -q "post-setup"; then
        log_info "Taking initial post-setup snapshot..."
        sudo snapper -c root create --description "post-setup"
    else
        log_warn "Initial snapshot already exists"
    fi

    summary_ok "Snapper (Btrfs snapshots)"
}

# ─── Section 19: VS Code ─────────────────────────────────────────────────────

setup_vscode() {
    log_section "Section 19: VS Code Extensions + Theme"

    if ! cmd_exists code; then
        log_warn "VS Code not installed, skipping"
        summary_skip "VS Code setup (not installed)"
        return
    fi

    local EXTENSIONS=(
        # Theme
        "Catppuccin.catppuccin-vsc"
        "Catppuccin.catppuccin-vsc-icons"
        # Language support
        "vscjava.vscode-java-pack"
        "ms-python.python"
        "ms-python.vscode-pylance"
        "golang.go"
        "llvm-vs-code-extensions.vscode-clangd"
        "ms-azuretools.vscode-docker"
        # Linting / formatting
        "esbenp.prettier-vscode"
        "dbaeumer.vscode-eslint"
        "charliermarsh.ruff"
        "timonwong.shellcheck"
        # Quality of life
        "usernamehw.errorlens"
        "eamodio.gitlens"
        "mhutchie.git-graph"
        "oderwat.indent-rainbow"
        "christian-kohler.path-intellisense"
    )

    for ext in "${EXTENSIONS[@]}"; do
        log_info "Installing VS Code extension: $ext"
        code --install-extension "$ext" --force
    done

    local VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"
    if [[ -f "$VSCODE_SETTINGS" ]]; then
        log_warn "VS Code settings.json already exists, skipping"
        summary_skip "VS Code settings (already exists)"
    else
        mkdir -p "$(dirname "$VSCODE_SETTINGS")"
        cat > "$VSCODE_SETTINGS" <<'EOF'
{
  "workbench.colorTheme": "Catppuccin Mocha",
  "workbench.iconTheme": "catppuccin-mocha",

  "editor.fontFamily": "'MesloLGS NF', 'Droid Sans Mono', monospace",
  "editor.fontSize": 14,
  "editor.fontLigatures": true,
  "editor.rulers": [100],
  "editor.minimap.enabled": false,
  "editor.bracketPairColorization.enabled": true,
  "editor.formatOnSave": true,
  "editor.defaultFormatter": "esbenp.prettier-vscode",

  "files.autoSave": "onFocusChange",

  "window.titleBarStyle": "custom",
  "workbench.startupEditor": "none",

  "terminal.integrated.fontFamily": "'MesloLGS NF'",

  "[python]": {
    "editor.defaultFormatter": "charliermarsh.ruff"
  },
  "[java]": {
    "editor.defaultFormatter": "redhat.java"
  },
  "[go]": {
    "editor.defaultFormatter": "golang.go",
    "editor.formatOnSave": true
  },
  "[c]": {
    "editor.defaultFormatter": "llvm-vs-code-extensions.vscode-clangd"
  },
  "[cpp]": {
    "editor.defaultFormatter": "llvm-vs-code-extensions.vscode-clangd"
  },
  "[shellscript]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  }
}
EOF
        log_info "VS Code settings.json written."
        summary_ok "VS Code extensions + config"
    fi
}

# ─── Section 20b: KDE Plasma Configuration ───────────────────────────────────

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
        log_warn "kwriteconfig not found; cannot write $file [$group] $key"
        return 1
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
        log_warn "kwriteconfig not found; cannot delete $file [$group] $key"
        return 1
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

configure_kde() {
    log_section "Section 20b: KDE Plasma Configuration"

    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        log_warn "No D-Bus session detected (running via SSH?). Skipping KDE settings."
        summary_skip "KDE config (no D-Bus session)"
        return
    fi

    if ! command -v kwriteconfig6 >/dev/null 2>&1 \
       && ! command -v kwriteconfig5 >/dev/null 2>&1; then
        log_warn "Neither kwriteconfig6 nor kwriteconfig5 found — install kf6-kconfig (or kconfig5) first"
        summary_skip "KDE config (kwriteconfig missing)"
        return
    fi

    clear_no_color_environment

    local terminal_app="konsole"
    if command -v ghostty >/dev/null 2>&1; then
        terminal_app="ghostty"
    elif ! command -v konsole >/dev/null 2>&1; then
        log_warn "Neither ghostty nor konsole found; leaving KDE terminal setting unchanged"
        terminal_app=""
    fi

    # Interface
    kde_write kdeglobals General ColorScheme BreezeDark
    kde_write kdeglobals Icons Theme Papirus-Dark
    kde_write kdeglobals KDE SingleClick false
    [[ -n "$terminal_app" ]] && kde_write kdeglobals General TerminalApplication "$terminal_app"

    local cursor_theme
    cursor_theme=$(ls "$HOME/.local/share/icons/" 2>/dev/null | grep -i "catppuccin.*mocha.*cursor" | head -1 || true)
    if [[ -n "$cursor_theme" ]]; then
        kde_write kdeglobals Mouse cursorTheme "$cursor_theme"
        kde_write kcminputrc Mouse cursorTheme "$cursor_theme"
    else
        log_warn "Catppuccin cursor not found in ~/.local/share/icons — skipping cursor theme"
    fi

    # Fonts: remove user overrides so Plasma falls back to its default font set.
    kde_delete kdeglobals General font
    kde_delete kdeglobals General menuFont
    kde_delete kdeglobals General toolBarFont
    kde_delete kdeglobals General smallestReadableFont
    kde_delete kdeglobals General fixed
    kde_delete kdeglobals WM activeFont

    # Keyboard layouts
    kde_write kxkbrc Layout Use true
    kde_write kxkbrc Layout LayoutList "us,ara"
    kde_write kxkbrc Layout VariantList ","

    # Night Color (8pm → 7am, warm 4000K)
    kde_write kwinrc NightColor Active true
    kde_write kwinrc NightColor Mode Times
    kde_write kwinrc NightColor EveningBeginFixed 2000
    kde_write kwinrc NightColor MorningBeginFixed 700
    kde_write kwinrc NightColor NightTemperature 4000
    kde_write kwinrc NightColor TransitionTime 30

    # Dolphin/File dialogs
    kde_write dolphinrc General BrowseThroughArchives true
    kde_write dolphinrc General OpenExternallyCalledFolderInNewTab true
    kde_write dolphinrc General RememberOpenedTabs false
    kde_write dolphinrc General ShowFullPath true
    kde_write dolphinrc General ShowSelectionToggle true
    kde_write kdeglobals "KFileDialog Settings" "Sort directories first" true

    # Default apps
    if [[ -f /usr/share/applications/firefox.desktop ]] || [[ -f "$HOME/.local/share/applications/firefox.desktop" ]]; then
        xdg-settings set default-web-browser firefox.desktop 2>/dev/null || \
            log_warn "Could not set default browser"
    fi
    for mime in video/mp4 video/x-matroska video/x-msvideo video/webm video/quicktime; do
        xdg-mime default vlc.desktop "$mime"
    done

    # System
    local current_host
    current_host="$(hostnamectl --static 2>/dev/null || hostname)"
    case "$current_host" in
        localhost|localhost.localdomain|archlinux|""|"$DISTRO")
            sudo hostnamectl set-hostname "$DISTRO"
            log_info "Hostname set to $DISTRO"
            ;;
        *)
            log_warn "Hostname already customized ($current_host), leaving unchanged"
            ;;
    esac
    sudo timedatectl set-timezone Africa/Casablanca
    # Power profile is handled by the dedicated 'power' section.

    kde_apply_runtime_settings BreezeDark "$cursor_theme"

    summary_ok "KDE Plasma configuration"
}

# ─── Section 22: Dotfiles ────────────────────────────────────────────────────

setup_dotfiles() {
    log_section "Section 22: Dotfiles"

    local FILES=(
        ".zshrc"
        ".p10k.zsh"
        ".gitconfig"
        ".gitconfig-work"
        ".gitconfig-imedia24"
        ".config/ghostty/config"
        ".config/fastfetch/config.jsonc"
        ".config/fontconfig/fonts.conf"
        ".config/fontconfig/conf.d/99-kamal-prefer-inter.conf"
        ".config/mozilla/firefox/user.js"
        ".config/Code/User/settings.json"
        ".config/opencode/opencode.jsonc"
        ".pi/agent/settings.json"
        ".pi/agent/keybindings.json"
    )

    FILES+=(
        ".local/bin/fix-steam-shortcuts"
        ".config/systemd/user/fix-steam-shortcuts.service"
        ".config/systemd/user/fix-steam-shortcuts.path"
    )

    for file in "${FILES[@]}"; do
        local source="$DOTFILES_DIR/$file"
        local target="$HOME/$file"

        case "$file" in
            .config/mozilla/firefox/user.js)
                local firefox_profile
                firefox_profile=$(grep '^Path=' "$HOME/.config/mozilla/firefox/profiles.ini" 2>/dev/null | head -1 | cut -d= -f2 || true)
                if [[ -n "$firefox_profile" ]]; then
                    target="$HOME/.config/mozilla/firefox/$firefox_profile/user.js"
                else
                    log_warn "Firefox profile not found for $file — skipping"
                    continue
                fi
                ;;
        esac

        if [[ ! -f "$source" ]]; then
            log_warn "Not found in dotfiles: $file — skipping"
            continue
        fi

        mkdir -p "$(dirname "$target")"

        if [[ -L "$target" ]]; then
            # Legacy symlink (this repo used to ln -s into dotfiles/). Drop it
            # silently — the copy below is the new source of truth.
            rm -f "$target"
        elif [[ -e "$target" ]] && ! cmp -s "$source" "$target"; then
            mkdir -p "$BACKUP_DIR/$(dirname "$file")"
            mv "$target" "$BACKUP_DIR/$file"
            log_warn "Backed up $target → $BACKUP_DIR/$file"
        fi

        cp -p "$source" "$target"
        log_info "Installed ~/$file"
    done

    summary_ok "Dotfiles"
}

# ─── Section 23: Default Shell ───────────────────────────────────────────────

set_default_shell() {
    log_section "Section 23: Default Shell"

    local ZSH_PATH
    ZSH_PATH="$(command -v zsh || true)"

    if [[ -z "$ZSH_PATH" ]]; then
        log_warn "zsh is not installed — run the 'shell' / 'packages' sections first"
        summary_skip "Default shell (zsh not installed)"
        return
    fi

    if [[ "$SHELL" == "$ZSH_PATH" ]]; then
        log_warn "zsh is already the default shell"
        summary_skip "Default shell (already zsh)"
        return
    fi

    grep -qxF "$ZSH_PATH" /etc/shells || echo "$ZSH_PATH" | sudo tee -a /etc/shells > /dev/null
    chsh -s "$ZSH_PATH" "$USER"
    log_info "Default shell changed to zsh."
    summary_ok "Default shell → zsh"
}

# ─── Summary + Reboot ────────────────────────────────────────────────────────

print_summary() {
    log_section "Summary"

    for line in "${SUMMARY[@]}"; do
        echo -e "$line"
    done

    echo ""
    local END_TIME ELAPSED
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log_info "Completed in $(printf '%dm %ds' $((ELAPSED / 60)) $((ELAPSED % 60)))"
}

reboot_prompt() {
    echo ""
    log_warn "The following require a reboot to take effect:"
    log_warn "  • Docker + libvirt group membership"
    log_warn "  • Default shell change to zsh"
    require_desktop kde && log_warn "  • KDE Plasma settings reload/login"
    echo ""
    read -rp "Reboot now? [y/N]: " answer
    if [[ "${answer,,}" == "y" ]]; then
        log_info "Rebooting..."
        sudo reboot
    else
        log_info "Reboot skipped. Please reboot manually when ready."
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    exec > >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)

    log_info "Setup started at $(date)"
    echo ""

    preflight_checks

    run_section git           configure_git
    run_section pacman        configure_pacman
    run_section repos         enable_repos
    run_section upgrade       system_upgrade
    run_section packages      install_packages
    run_section ms-fonts      install_ms_fonts
    run_section extra-tools   install_extra_tools
    run_section ghostty       install_ghostty
    run_section flatpak       setup_flatpak
    run_section steam-components install_steam_components
    run_section steam-shortcuts fix_steam_shortcuts
    run_section asus          install_asus_tools
    run_section fonts         install_fonts
    run_section shell         install_shell_extras
    run_section node          install_node
    run_section ssh           setup_ssh
    run_section services      setup_services
    run_section power         setup_power_profiles
    run_section security      setup_security
    run_section virt          setup_virtualization
    run_section snapper       setup_snapper
    run_section vscode        setup_vscode
    run_section kde           configure_kde
    run_section dotfiles      setup_dotfiles
    run_section shell-default set_default_shell

    print_summary
    reboot_prompt

    log_info "Setup completed at $(date)"
}

main "$@"
