#!/usr/bin/env bash
# Distro detection + package-manager abstractions.
#
# Sets globals on detection:
#   DISTRO   — fedora | ubuntu | debian | arch
#   DISTRO_FAMILY — fedora | debian | arch (groups Ubuntu under Debian)
#   PKG_MGR  — dnf | apt | pacman
#
# Public helpers (call after detect_distro):
#   pkg_install <pkgs...>     — install, skip already-installed
#   pkg_install_one <pkgs...> — install first available from candidates
#   pkg_remove <pkgs...>      — remove if installed
#   pkg_installed <pkg>       — is installed?
#   pkg_available <pkg>       — exists in enabled repos?
#   pkg_swap <from> <to>      — replace package (Fedora-only meaningfully)
#   pm_upgrade                — full system upgrade
#   add_repo <name> <args...> — distro-specific; see per-pm helpers below
#   install_local_pkg <file>  — install a downloaded .rpm/.deb/.pkg.tar.zst
#   bootstrap_aur             — install yay if missing (arch only)

detect_distro() {
    if ! source /etc/os-release 2>/dev/null; then
        log_error "Cannot read /etc/os-release; unsupported system"
        exit 1
    fi

    case "${ID:-}" in
        fedora)
            DISTRO=fedora
            DISTRO_FAMILY=fedora
            PKG_MGR=dnf
            ;;
        ubuntu)
            DISTRO=ubuntu
            DISTRO_FAMILY=debian
            PKG_MGR=apt
            ;;
        debian)
            DISTRO=debian
            DISTRO_FAMILY=debian
            PKG_MGR=apt
            ;;
        arch|cachyos|endeavouros|manjaro)
            DISTRO=arch
            DISTRO_FAMILY=arch
            PKG_MGR=pacman
            ;;
        *)
            # Try ID_LIKE before giving up
            case "${ID_LIKE:-}" in
                *fedora*|*rhel*) DISTRO=fedora; DISTRO_FAMILY=fedora; PKG_MGR=dnf ;;
                *debian*|*ubuntu*) DISTRO=ubuntu; DISTRO_FAMILY=debian; PKG_MGR=apt ;;
                *arch*) DISTRO=arch; DISTRO_FAMILY=arch; PKG_MGR=pacman ;;
                *)
                    log_error "Unsupported distro: ID=${ID:-unknown} ID_LIKE=${ID_LIKE:-}"
                    log_error "Supported: Fedora, Ubuntu, Debian, Arch"
                    exit 1
                    ;;
            esac
            ;;
    esac

    export DISTRO DISTRO_FAMILY PKG_MGR
}

# ─── pkg_installed ────────────────────────────────────────────────────────────

pkg_installed() {
    case "$PKG_MGR" in
        dnf)    rpm -q "$1" &>/dev/null || rpm -q --whatprovides "$1" &>/dev/null ;;
        apt)    dpkg -s "$1" 2>/dev/null | grep -q '^Status: install ok installed' ;;
        pacman) pacman -Qi "$1" &>/dev/null ;;
    esac
}

# ─── pkg_available ────────────────────────────────────────────────────────────

pkg_available() {
    case "$PKG_MGR" in
        dnf)    dnf_pkg_available "$1" ;;
        apt)    apt-cache show "$1" 2>/dev/null | grep -q '^Package:' ;;
        pacman)
            # pacman repo first; if not in repo, optimistically allow — the
            # install path bootstraps yay and queries AUR. Avoids needing yay
            # just to answer "is this installable?".
            pacman -Si "$1" &>/dev/null && return 0
            _aur_available "$1" && return 0
            # No yay yet → assume AUR; install path will resolve it.
            return 0
            ;;
    esac
}

# ─── pkg_install ──────────────────────────────────────────────────────────────

pkg_install() {
    local to_install=()
    local pkg
    for pkg in "$@"; do
        if pkg_installed "$pkg"; then
            log_warn "$pkg already installed, skipping"
        elif pkg_available "$pkg"; then
            to_install+=("$pkg")
        else
            log_warn "$pkg not available in enabled repositories, skipping"
        fi
    done
    [[ ${#to_install[@]} -eq 0 ]] && return 0

    log_info "Installing: ${to_install[*]}"
    case "$PKG_MGR" in
        dnf)
            dnf_run_with_repair install -y "${to_install[@]}" || {
                log_warn "Package install failed, continuing: ${to_install[*]}"
                return 0
            }
            ;;
        apt)
            sudo apt-get install -y "${to_install[@]}" || {
                log_warn "Package install failed, continuing: ${to_install[*]}"
                return 0
            }
            ;;
        pacman)
            _pacman_install "${to_install[@]}" || {
                log_warn "Package install failed, continuing: ${to_install[*]}"
                return 0
            }
            ;;
    esac
}

# Install the first candidate package that's available (dnf-style fallback).
pkg_install_one() {
    local pkg
    for pkg in "$@"; do
        if pkg_installed "$pkg"; then
            log_warn "$pkg already installed, skipping"
            return 0
        fi
        if pkg_available "$pkg"; then
            pkg_install "$pkg"
            return 0
        fi
    done
    log_warn "None of these packages available: $*"
    return 0
}

# ─── pkg_remove ───────────────────────────────────────────────────────────────

pkg_remove() {
    local to_remove=()
    local pkg
    for pkg in "$@"; do
        pkg_installed "$pkg" && to_remove+=("$pkg")
    done
    [[ ${#to_remove[@]} -eq 0 ]] && return 0

    log_info "Removing: ${to_remove[*]}"
    case "$PKG_MGR" in
        dnf)    sudo dnf remove -y "${to_remove[@]}" || true ;;
        apt)    sudo apt-get remove -y "${to_remove[@]}" || true ;;
        pacman) sudo pacman -Rns --noconfirm "${to_remove[@]}" || true ;;
    esac
}

# ─── pkg_swap (Fedora only; on others, install dest + remove src) ─────────────

pkg_swap() {
    local from="$1" to="$2"
    case "$PKG_MGR" in
        dnf)
            sudo dnf swap -y "$from" "$to" --allowerasing || true
            ;;
        apt|pacman)
            pkg_install "$to"
            pkg_remove "$from"
            ;;
    esac
}

# ─── pm_upgrade ───────────────────────────────────────────────────────────────

pm_upgrade() {
    case "$PKG_MGR" in
        dnf)
            sudo dnf upgrade --refresh -y || log_warn "System upgrade had issues"
            ;;
        apt)
            sudo apt-get update || log_warn "apt update had issues"
            sudo apt-get upgrade -y || log_warn "apt upgrade had issues"
            ;;
        pacman)
            sudo pacman -Syu --noconfirm || log_warn "System upgrade had issues"
            ;;
    esac
}

# ─── install_local_pkg ────────────────────────────────────────────────────────

install_local_pkg() {
    local file="$1"
    case "$PKG_MGR" in
        dnf)    dnf_run_optional install -y "$file" ;;
        apt)    sudo apt-get install -y "$file" ;;
        pacman) sudo pacman -U --noconfirm "$file" ;;
    esac
}

# ─── repo helpers ─────────────────────────────────────────────────────────────

# Add a deb repository: add_apt_repo <name> <key-url> <repo-line>
add_apt_repo() {
    local name="$1" key_url="$2" repo_line="$3"
    local keyring="/etc/apt/keyrings/${name}.gpg"
    local listfile="/etc/apt/sources.list.d/${name}.list"

    sudo install -d -m 0755 /etc/apt/keyrings
    if [[ ! -f "$keyring" ]]; then
        curl -fsSL "$key_url" | sudo gpg --dearmor -o "$keyring"
    fi
    if [[ ! -f "$listfile" ]]; then
        echo "$repo_line" | sudo tee "$listfile" > /dev/null
        sudo apt-get update -qq
    fi
}

# ─── AUR support (Arch) ───────────────────────────────────────────────────────

bootstrap_aur() {
    [[ "$PKG_MGR" != "pacman" ]] && return 0
    if cmd_exists yay; then
        return 0
    fi
    log_info "Bootstrapping AUR helper (yay)..."
    sudo pacman -S --needed --noconfirm base-devel git
    local tmp
    tmp=$(mktemp -d)
    git clone --depth=1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
    (cd "$tmp/yay-bin" && makepkg -si --noconfirm)
    rm -rf "$tmp"
}

_aur_available() {
    cmd_exists yay || return 1
    yay -Si "$1" &>/dev/null
}

# Install via pacman first; if not in repos, fall back to AUR via yay.
_pacman_install() {
    local from_repo=() from_aur=()
    local pkg
    for pkg in "$@"; do
        if pacman -Si "$pkg" &>/dev/null; then
            from_repo+=("$pkg")
        else
            from_aur+=("$pkg")
        fi
    done
    if [[ ${#from_repo[@]} -gt 0 ]]; then
        sudo pacman -S --needed --noconfirm "${from_repo[@]}" || return 1
    fi
    if [[ ${#from_aur[@]} -gt 0 ]]; then
        bootstrap_aur
        yay -S --needed --noconfirm "${from_aur[@]}" || return 1
    fi
}

# ─── distro guard ─────────────────────────────────────────────────────────────

# require_distro fedora ubuntu — return 0 if current distro matches one of args,
# else log a skip and return 1. Use to gate sections that only make sense on
# certain distros.
require_distro() {
    local d
    for d in "$@"; do
        [[ "$DISTRO" == "$d" ]] && return 0
        [[ "$DISTRO_FAMILY" == "$d" ]] && return 0
    done
    return 1
}

# ─── desktop environment detection ────────────────────────────────────────────

# Sets DESKTOP_ENV to one of: gnome, kde, xfce, cinnamon, mate, lxqt, other, none
detect_desktop() {
    local raw="${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}"
    raw="${raw,,}"   # lowercase

    if [[ -z "$raw" ]]; then
        DESKTOP_ENV=none
    elif [[ "$raw" == *gnome* || "$raw" == *unity* ]]; then
        DESKTOP_ENV=gnome
    elif [[ "$raw" == *kde* || "$raw" == *plasma* ]]; then
        DESKTOP_ENV=kde
    elif [[ "$raw" == *xfce* ]]; then
        DESKTOP_ENV=xfce
    elif [[ "$raw" == *cinnamon* ]]; then
        DESKTOP_ENV=cinnamon
    elif [[ "$raw" == *mate* ]]; then
        DESKTOP_ENV=mate
    elif [[ "$raw" == *lxqt* ]]; then
        DESKTOP_ENV=lxqt
    else
        DESKTOP_ENV=other
    fi
    export DESKTOP_ENV
}

# require_desktop gnome [kde …] — return 0 if current DE matches one of args.
require_desktop() {
    local de
    for de in "$@"; do
        [[ "$DESKTOP_ENV" == "$de" ]] && return 0
    done
    return 1
}
