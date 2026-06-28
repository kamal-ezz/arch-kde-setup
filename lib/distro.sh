#!/usr/bin/env bash
# Arch Linux package-manager helpers.

is_linux() { [[ "$(uname -s)" == "Linux" ]]; }

require_linux() {
    if is_linux; then
        return 0
    fi
    log_error "${1:-This operation} is Linux-only"
    return 1
}

detect_distro() {
    require_linux "Distro detection" || exit 1

    if ! source /etc/os-release 2>/dev/null; then
        log_error "Cannot read /etc/os-release"
        exit 1
    fi

    case "${ID:-}:${ID_LIKE:-}" in
        arch:*|cachyos:*|endeavouros:*|manjaro:*|*:arch*)
            DISTRO=arch
            DISTRO_FAMILY=arch
            PKG_MGR=pacman
            ;;
        *)
            log_error "Unsupported system: this repo targets Arch Linux only"
            log_error "Detected ID=${ID:-unknown} ID_LIKE=${ID_LIKE:-}"
            exit 1
            ;;
    esac

    export DISTRO DISTRO_FAMILY PKG_MGR
}

pkg_installed() {
    pacman -Qi "$1" &>/dev/null
}

pkg_available() {
    pacman -Si "$1" &>/dev/null && return 0
    _aur_available "$1" && return 0
    return 0
}

pkg_install() {
    local to_install=()
    local pkg

    for pkg in "$@"; do
        if pkg_installed "$pkg"; then
            log_warn "$pkg already installed, skipping"
        elif pkg_available "$pkg"; then
            to_install+=("$pkg")
        else
            log_warn "$pkg not available, skipping"
        fi
    done

    [[ ${#to_install[@]} -eq 0 ]] && return 0

    log_info "Installing: ${to_install[*]}"
    _pacman_install "${to_install[@]}" || {
        log_warn "Package install failed, continuing: ${to_install[*]}"
        return 0
    }
}

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
    log_warn "None of these packages are available: $*"
    return 0
}

pkg_remove() {
    local to_remove=()
    local pkg

    for pkg in "$@"; do
        pkg_installed "$pkg" && to_remove+=("$pkg")
    done

    [[ ${#to_remove[@]} -eq 0 ]] && return 0

    log_info "Removing: ${to_remove[*]}"
    sudo pacman -Rns --noconfirm "${to_remove[@]}" || true
}

pkg_swap() {
    local from="$1" to="$2"
    pkg_install "$to"
    pkg_remove "$from"
}

pm_upgrade() {
    sudo pacman -Syu --noconfirm || log_warn "System upgrade had issues"
}

install_local_pkg() {
    local file="$1"
    sudo pacman -U --noconfirm "$file"
}

bootstrap_aur() {
    if cmd_exists yay; then
        return 0
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    log_info "Installing yay AUR helper..."

    sudo pacman -Sy --needed --noconfirm base-devel git
    git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
    (
        cd "$tmpdir/yay"
        makepkg -si --noconfirm
    )
    rm -rf "$tmpdir"
}

_aur_available() {
    if cmd_exists yay; then
        yay -Si "$1" &>/dev/null
    else
        return 1
    fi
}

_pacman_install() {
    local repo_pkgs=()
    local aur_pkgs=()
    local pkg

    for pkg in "$@"; do
        if pacman -Si "$pkg" &>/dev/null; then
            repo_pkgs+=("$pkg")
        else
            aur_pkgs+=("$pkg")
        fi
    done

    [[ ${#repo_pkgs[@]} -gt 0 ]] && sudo pacman -S --needed --noconfirm "${repo_pkgs[@]}"

    if [[ ${#aur_pkgs[@]} -gt 0 ]]; then
        bootstrap_aur
        yay -S --needed --noconfirm "${aur_pkgs[@]}"
    fi
}

require_distro() {
    [[ "$DISTRO" == "arch" ]]
}
