#!/usr/bin/env bash

preflight_checks() {
    log_section "Section 1: Pre-flight Checks"

    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script as root. Run as your regular user."
        exit 1
    fi
    log_info "Running as user: $USER"

    detect_distro
    log_info "$DISTRO ${VERSION_ID:-} detected (family: $DISTRO_FAMILY, pkg-mgr: $PKG_MGR)"
    if [[ "$DISTRO" == "macos" ]]; then
        log_info "macOS detected — Linux-only sections (NVIDIA, ASUS, GRUB, systemd, Snapper) will be skipped"
        # Bootstrap Homebrew early: every subsequent section on macOS depends on
        # it, and the user may run a single section via --only without Section 2.
        bootstrap_homebrew
    elif [[ "$DISTRO" != "fedora" ]]; then
        log_warn "Non-Fedora paths are best-effort and untested. Report issues if you hit them."
    fi

    detect_desktop
    log_info "Desktop environment: $DESKTOP_ENV"
    if is_linux; then
        case "$DESKTOP_ENV" in
            gnome|kde)
                log_info "Desktop-specific sections will be selected for $DESKTOP_ENV"
                ;;
            none)
                log_warn "No desktop session detected — desktop-specific sections will be skipped."
                ;;
            *)
                log_warn "Unsupported desktop ($DESKTOP_ENV) — GNOME/KDE-specific sections will be skipped."
                ;;
        esac
    fi

    if ! sudo -v 2>/dev/null; then
        log_error "sudo access is required but not available."
        exit 1
    fi
    log_info "sudo access confirmed"

    # Keep sudo alive throughout the script
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null ) &
    SUDO_KEEPALIVE_PID=$!
    trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null; err_handler \$LINENO" ERR
    trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null" EXIT

    if check_internet; then
        log_info "Network connectivity confirmed"
        HAS_INTERNET=1
    else
        log_warn "No internet connection detected — sections that require network access will be skipped."
        HAS_INTERNET=0
    fi
    export HAS_INTERNET

    local free_gb
    if is_macos; then
        free_gb=$(df -g / | awk 'NR==2 {print $4}')
    else
        free_gb=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')
    fi
    if [[ "$free_gb" -lt 20 ]]; then
        log_error "Insufficient disk space: ${free_gb}GB free, 20GB required."
        exit 1
    fi
    log_info "Disk space OK: ${free_gb}GB free"
}
