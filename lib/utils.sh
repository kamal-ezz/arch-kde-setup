#!/usr/bin/env bash

cmd_exists() {
    command -v "$1" &>/dev/null
}

user_in_group() {
    id -nG "$USER" | tr ' ' '\n' | grep -qx "$1"
}

has_nvidia_hardware() {
    # macOS has not supported NVIDIA GPUs since 2019.
    is_linux || return 1
    # NVIDIA PCI vendor ID is 0x10de. Checking /sys avoids depending on lspci.
    grep -qi '^0x10de$' /sys/bus/pci/devices/*/vendor 2>/dev/null
}

has_asus_hardware() {
    # /sys/class/dmi/ is Linux-specific; always false on macOS.
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

add_dnf_repo_from_url() {
    local url="$1"

    # DNF5 (Fedora 41+): addrepo --from-repofile
    if sudo dnf config-manager addrepo --from-repofile="$url" 2>/dev/null; then
        return 0
    fi

    # Fallback: download the .repo file directly — works on DNF4 and DNF5
    local filename
    filename=$(basename "${url%%\?*}")
    if safe_curl -fsSL "$url" | sudo tee "/etc/yum.repos.d/${filename}" > /dev/null; then
        return 0
    fi

    log_warn "Could not add repo from $url — skipping"
    return 0
}

# True if DNF can install this package name or virtual provide.
dnf_pkg_available() {
    dnf repoquery --quiet --whatprovides "$1" --latest-limit=1 2>/dev/null | grep -q .
}

# Echo the first available package from the provided candidates.
dnf_first_available() {
    local pkg
    for pkg in "$@"; do
        if dnf_pkg_available "$pkg"; then
            printf '%s\n' "$pkg"
            return 0
        fi
    done
    return 1
}

# Latest evr (epoch:version-release) available in enabled repos for pkg.arch.
# Empty if not found.
dnf_latest_evr() {
    sudo dnf repoquery --quiet --latest-limit=1 --qf '%{evr}' "$1" 2>/dev/null \
        | head -n1
}

# For each package name, keep .x86_64 and .i686 only when both arches have the
# same latest evr in the repos. Mirror lag often leaves i686 ahead of x86_64,
# in which case attempting to upgrade i686 alone creates file conflicts against
# the installed x86_64 package — better to skip until x86_64 catches up.
# Args: package names. Echoes the filtered list of pkg.arch specs.
dnf_multilib_synced_specs() {
    local pkg evr_x evr_i
    for pkg in "$@"; do
        evr_x="$(dnf_latest_evr "${pkg}.x86_64")"
        evr_i="$(dnf_latest_evr "${pkg}.i686")"
        if [[ -z "$evr_x" || -z "$evr_i" ]]; then
            continue
        fi
        if [[ "$evr_x" != "$evr_i" ]]; then
            log_warn "Skipping ${pkg}: x86_64=${evr_x} vs i686=${evr_i} (mirror lag); will retry on next run"
            continue
        fi
        printf '%s.x86_64\n%s.i686\n' "$pkg" "$pkg"
    done
}

# Build --exclude options for i686 packages involved in file conflicts. This is
# the safe fallback when mirrors have i686 newer than x86_64: keep the already
# installed matching i686 build instead of trying to upgrade only i686.
dnf_i686_conflict_excludes() {
    local output_file="$1"
    grep -oE '[A-Za-z0-9_+.-]+-[0-9][^[:space:]]*\.i686' "$output_file" 2>/dev/null \
        | sed -E 's/-[0-9].*$//' \
        | sort -u \
        | sed 's/^/--exclude=/' \
        | sed 's/$/.i686/'
}

# Try to repair DNF file-conflict/multilib version mismatches, then callers retry.
# Common case: installing Steam/Wine pulls *.i686 while installed *.x86_64 is one
# build behind, producing "conflicts with file from package ...x86_64" errors.
dnf_repair_transaction_conflicts() {
    local output_file="$1"
    local pkgs=()
    local pkg_specs=()

    if ! grep -qE 'conflicts with file from package|Rpm transaction failed|Transaction failed' "$output_file" 2>/dev/null; then
        return 1
    fi

    # Extract package names from strings like:
    #   mesa-vulkan-drivers-26.0.5-3.fc44.x86_64
    #   gnutls-3.8.13-1.fc44.i686
    # This strips from the first dash followed by a digit, leaving the name.
    mapfile -t pkgs < <(
        grep -oE '[A-Za-z0-9_+.-]+-[0-9][^[:space:]]*\.(x86_64|i686)' "$output_file" 2>/dev/null \
            | sed -E 's/-[0-9].*$//' \
            | sort -u
    )

    sudo dnf clean expire-cache || true

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        # Only sync arches whose latest evr matches across x86_64 and i686.
        # Forcing a sync when only i686 has a newer build available reproduces
        # the same file conflict on every retry.
        mapfile -t pkg_specs < <(dnf_multilib_synced_specs "${pkgs[@]}")

        if [[ ${#pkg_specs[@]} -eq 0 ]]; then
            log_warn "DNF transaction conflict detected but no multilib-aligned upgrade is available yet (likely mirror lag)"
            return 1
        fi

        log_warn "DNF transaction conflict detected; synchronizing affected packages: ${pkg_specs[*]}"
        if sudo dnf distro-sync --refresh --allowerasing -y "${pkg_specs[@]}" || \
           sudo dnf upgrade --refresh --best --allowerasing -y "${pkg_specs[@]}"; then
            return 0
        fi

        # Stronger repair: if both arches are already installed at different
        # versions, RPM can still try to install the new i686 package while the
        # old x86_64 package owns the same files. Temporarily remove only the
        # stale i686 copies from the RPM DB, update x86_64, then the caller's
        # retry will install/sync i686 again at the matching version.
        local installed_i686=()
        local x86_specs=()
        for pkg in "${pkgs[@]}"; do
            pkg_installed "${pkg}.i686" && installed_i686+=("${pkg}.i686")
            x86_specs+=("${pkg}.x86_64")
        done

        if [[ ${#installed_i686[@]} -gt 0 ]]; then
            log_warn "Standard sync failed; temporarily removing stale i686 packages: ${installed_i686[*]}"
            sudo rpm -e --nodeps "${installed_i686[@]}" || return 1
        fi

        log_warn "Upgrading x86_64 packages after stale i686 removal: ${x86_specs[*]}"
        sudo dnf upgrade --refresh --best --allowerasing -y "${x86_specs[@]}" || \
            sudo dnf distro-sync --refresh --allowerasing -y "${x86_specs[@]}" || \
            return 1
        return 0
    else
        log_warn "DNF transaction conflict detected; synchronizing installed packages"
        sudo dnf distro-sync --refresh --allowerasing -y || return 1
    fi
}

# Run any DNF transaction, auto-repairing transaction/file conflicts and retrying.
dnf_run_with_repair() {
    local attempt dnf_log

    for attempt in 1 2 3; do
        dnf_log="$(mktemp /tmp/fedora-setup-dnf.XXXXXX.log)"

        if sudo dnf "$@" 2>&1 | tee "$dnf_log"; then
            rm -f "$dnf_log"
            return 0
        fi

        if [[ "$attempt" -eq 3 ]]; then
            log_error "DNF command failed after automatic repairs: dnf $*"
            log_error "Last DNF output preserved at: $dnf_log"
            return 1
        fi

        log_warn "DNF command failed; checking whether it can be repaired automatically: dnf $*"
        if dnf_repair_transaction_conflicts "$dnf_log"; then
            log_info "Retrying after DNF repair (attempt $((attempt + 1))/3): dnf $*"
            rm -f "$dnf_log"
            continue
        fi

        local excludes=()
        mapfile -t excludes < <(dnf_i686_conflict_excludes "$dnf_log")
        if [[ ${#excludes[@]} -gt 0 ]]; then
            log_warn "Retrying while excluding conflicting i686 updates: ${excludes[*]}"
            if sudo dnf "${excludes[@]}" "$@"; then
                rm -f "$dnf_log"
                return 0
            fi
        fi

        rm -f "$dnf_log"
        return 1
    done
}

# Install multiple packages in one dnf call, skipping already-installed ones.
# On DNF transaction/file conflicts, automatically repair and retry once.
dnf_install_bulk() {
    local to_install=()
    for pkg in "$@"; do
        if pkg_installed "$pkg"; then
            log_warn "$pkg already installed/provided, skipping"
        elif dnf_pkg_available "$pkg"; then
            to_install+=("$pkg")
        else
            log_warn "$pkg is not available in enabled repositories, skipping"
        fi
    done
    if [[ ${#to_install[@]} -eq 0 ]]; then
        return
    fi

    log_info "Installing: ${to_install[*]}"
    dnf_run_with_repair install -y "${to_install[@]}" || {
        log_warn "DNF install failed, continuing: ${to_install[*]}"
        return 0
    }
}

# Best-effort DNF wrapper for sections where package failures should not abort
# the whole setup script.
dnf_run_optional() {
    dnf_run_with_repair "$@" || {
        log_warn "DNF command failed, continuing: dnf $*"
        return 0
    }
}

# True if `dnf swap <from> <to>` would downgrade one or more installed packages.
# RPM Fusion's *-freeworld mesa/ffmpeg builds routinely lag Fedora's updates
# repo; because the mesa stack is version-locked, swapping in a lagging freeworld
# driver drags the whole stack backwards (a 13-package downgrade), which then
# fights every `dnf upgrade` and repeats on every setup run. Dry-run the swap and
# refuse it when it would move anything to an older version.
dnf_swap_would_downgrade() {
    local from="$1" to="$2" out
    out="$(sudo dnf swap "$from" "$to" --allowerasing --assumeno 2>&1 || true)"
    grep -qiE 'downgrad(e|ing|ed)' <<< "$out"
}

# curl wrapper with retries. Covers transient failures: short network blips,
# GitHub/SourceForge/etc. having a bad minute, slow DNS, 5xx responses.
# --retry-all-errors needs curl ≥ 7.71 (2020); all supported distros have it.
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
