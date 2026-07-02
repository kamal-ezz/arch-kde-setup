#!/usr/bin/env bash
# Arch Linux package groups.
#
# The actual package lists live in packages/*.list — one package per line,
# '#' comments allowed. A '#!' directive on the first line marks special
# groups: '#!absent' (should NOT be installed), '#!candidates' (install the
# first available one), '#!optional' (informational only, not drift).
# The functions below keep the old pkgs_* API for setup.sh.

PKG_LISTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../packages" && pwd)"

# Print the packages in a group as one space-separated line.
pkgs_from_list() {
    local file="$PKG_LISTS_DIR/$1.list"
    if [[ ! -f "$file" ]]; then
        log_warn "Package list not found: $file"
        return 0
    fi
    grep -vE '^[[:space:]]*(#|$)' "$file" | tr '\n' ' ' | sed 's/ $//'
    echo ""
}

# Print the '#!directive' of a group ('absent', 'candidates', 'optional')
# or 'normal' if it has none.
pkgs_list_directive() {
    local file="$PKG_LISTS_DIR/$1.list"
    local d
    d=$(head -1 "$file" 2>/dev/null | grep -oE '^#!(absent|candidates|optional)' || true)
    if [[ -n "$d" ]]; then echo "${d#\#!}"; else echo "normal"; fi
}

# Enumerate all group names (list file basenames).
pkgs_groups() {
    local f
    for f in "$PKG_LISTS_DIR"/*.list; do
        basename "$f" .list
    done
}

pkgs_system_tools()       { pkgs_from_list system-tools; }
pkgs_dev()                { pkgs_from_list dev; }
pkgs_java_candidates()    { pkgs_from_list java-candidates; }
pkgs_codecs()             { pkgs_from_list codecs; }
pkgs_gaming()             { pkgs_from_list gaming; }
pkgs_steam()              { pkgs_from_list steam; }
pkgs_themes()             { pkgs_from_list themes; }
pkgs_browser()            { pkgs_from_list browser; }
pkgs_kde_only()           { pkgs_from_list kde; }
pkgs_qt()                 { pkgs_from_list qt; }
pkgs_fonts_arabic()       { pkgs_from_list fonts-arabic; }
pkgs_bluetooth()          { pkgs_from_list bluetooth; }
pkgs_power()              { pkgs_from_list power; }
pkgs_bloat()              { pkgs_from_list bloat; }
pkgs_ghostty_build_deps() { pkgs_from_list ghostty-build-deps; }
pkgs_virt()               { pkgs_from_list virt; }
pkgs_snapper()            { pkgs_from_list snapper; }
pkgs_firewall()           { pkgs_from_list firewall; }
pkgs_docker_engine()      { pkgs_from_list docker; }
pkgs_ms_fonts()           { pkgs_from_list ms-fonts; }

# Packages that conflict with the Docker engine install (kept inline: this is
# reconcile logic, not desired state).
pkgs_docker_conflicts() { echo "docker"; }
