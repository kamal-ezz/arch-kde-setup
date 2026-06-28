#!/usr/bin/env bash

cmd_exists() {
    command -v "$1" &>/dev/null
}

user_in_group() {
    id -nG "$USER" | tr ' ' '\n' | grep -qx "$1"
}

detect_desktop() {
    local desktop_hint="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-}}"
    desktop_hint="${desktop_hint,,}"

    case "$desktop_hint" in
        *kde*|*plasma*)
            DESKTOP_ENV="kde"
            ;;
        "")
            DESKTOP_ENV="none"
            ;;
        *)
            DESKTOP_ENV="$desktop_hint"
            ;;
    esac

    export DESKTOP_ENV
}

require_desktop() {
    local expected="$1"
    [[ "${DESKTOP_ENV:-none}" == "$expected" ]]
}

has_asus_hardware() {
    is_linux || return 1
    local vendor product board
    vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
    product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    board="$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || true)"

    printf '%s\n%s\n%s\n' "$vendor" "$product" "$board" | grep -Eiq 'ASUSTeK|ASUS'
}

# Quick reachability probe. Re-checked each call so a network that comes up
# (or drops) mid-run is reflected. Five-second cap keeps it from stalling.
check_internet() {
    curl -fsS --head --max-time 5 -o /dev/null https://1.1.1.1 2>/dev/null \
        || curl -fsS --head --max-time 5 -o /dev/null https://8.8.8.8 2>/dev/null
}

# Section-level guard. Refreshes HAS_INTERNET if it was 0, then either returns
# 0 (proceed) or logs + records a skip and returns 1 so the caller can `return`.
require_internet() {
    local section="${1:-this section}"
    if [[ "${HAS_INTERNET:-0}" != "1" ]] && check_internet; then
        HAS_INTERNET=1
        export HAS_INTERNET
    fi
    if [[ "${HAS_INTERNET:-0}" == "1" ]]; then
        return 0
    fi
    log_warn "Skipping ${section}: no internet connection"
    summary_skip "${section} (offline)"
    return 1
}

# curl wrapper with retries. Covers transient failures: short network blips,
# GitHub/SourceForge/etc. having a bad minute, slow DNS, 5xx responses.
# --retry-all-errors needs curl ≥ 7.71.
# Pass any extra curl flags after the URL just like plain curl.
safe_curl() {
    curl --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 "$@"
}

# Fetch a single file from a GitHub repo without going through
# raw.githubusercontent.com (which some ISPs block). Tries jsDelivr's GitHub
# mirror first, then falls back to extracting the file from the codeload.github.com
# tarball for the given ref.
#
# Usage: gh_raw_fetch <user/repo> <ref> <path/in/repo> <output-file>
gh_raw_fetch() {
    local repo="$1" ref="$2" path="$3" out="$4"

    mkdir -p "$(dirname "$out")"

    # jsDelivr rejects unencoded spaces; encode them so filenames like
    # "MesloLGS NF Regular.ttf" go through the mirror instead of always
    # falling back to the tarball.
    local jsd_url="https://cdn.jsdelivr.net/gh/${repo}@${ref}/${path// /%20}"
    if safe_curl -fsSL "$jsd_url" -o "$out"; then
        return 0
    fi

    log_warn "jsDelivr fetch failed for ${repo}@${ref}/${path}; falling back to codeload tarball"

    local tmp tar found
    tmp=$(mktemp -d)
    tar="$tmp/src.tar.gz"
    if safe_curl -fsSL "https://codeload.github.com/${repo}/tar.gz/refs/heads/${ref}" -o "$tar" \
       && tar -xzf "$tar" -C "$tmp" --wildcards "*/${path}" 2>/dev/null; then
        found=$(find "$tmp" -type f -path "*/${path}" | head -1)
        if [[ -n "$found" ]]; then
            install -D -m 0644 "$found" "$out"
            rm -rf "$tmp"
            return 0
        fi
    fi
    rm -rf "$tmp"
    return 1
}

err_handler() {
    log_error "Script failed at line $1. Check $LOG_FILE for details."
    exit 1
}
