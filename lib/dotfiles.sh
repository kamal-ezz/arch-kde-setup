#!/usr/bin/env bash
# Symlink-based dotfiles management.
#
# The dotfiles/ tree IS the manifest: every file in it is symlinked into
# $HOME at the same relative path. The repo is the single source of truth —
# editing the file in $HOME edits the repo, so there is nothing to "capture".
# Requires DOTFILES_DIR to be set by the sourcing script.

: "${DOTFILES_BACKUP_DIR:=$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)}"

# List all tracked files as repo-relative paths.
dotfiles_manifest() {
    find "$DOTFILES_DIR" -type f -printf '%P\n' | sort
}

# Map a repo-relative path to its install location. Fails (return 1) when the
# target can't be resolved, e.g. no Firefox profile exists yet.
dotfiles_target() {
    local file="$1"
    case "$file" in
        .config/mozilla/firefox/user.js)
            local profile
            profile=$(grep '^Path=' "$HOME/.config/mozilla/firefox/profiles.ini" 2>/dev/null | head -1 | cut -d= -f2 || true)
            [[ -z "$profile" ]] && return 1
            echo "$HOME/.config/mozilla/firefox/$profile/user.js"
            ;;
        *)
            echo "$HOME/$file"
            ;;
    esac
}

# State of one tracked file:
#   linked        target is a symlink into the repo (desired state)
#   missing       target does not exist
#   unlinked-same target is a regular file with identical content
#   drifted       target is a regular file with different content
#   wrong-link    target is a symlink to somewhere else
#   no-target     target path can't be resolved on this host
dotfiles_status() {
    local file="$1" source target
    source="$DOTFILES_DIR/$file"
    target=$(dotfiles_target "$file") || { echo "no-target"; return 0; }
    if [[ -L "$target" ]]; then
        if [[ "$(readlink -f "$target")" == "$(readlink -f "$source")" ]]; then
            echo "linked"
        else
            echo "wrong-link"
        fi
    elif [[ ! -e "$target" ]]; then
        echo "missing"
    elif cmp -s "$source" "$target"; then
        echo "unlinked-same"
    else
        echo "drifted"
    fi
}

# Install one tracked file as a symlink. A regular file with local changes is
# backed up first, so apply is never silently destructive.
link_tracked_file() {
    local file="$1" source target
    source="$DOTFILES_DIR/$file"

    if [[ ! -f "$source" ]]; then
        log_warn "Not found in dotfiles: $file — skipping"
        return 0
    fi

    case "$(dotfiles_status "$file")" in
        linked)
            return 0
            ;;
        no-target)
            log_warn "No install target for $file on this host — skipping"
            return 0
            ;;
        drifted)
            target=$(dotfiles_target "$file")
            mkdir -p "$DOTFILES_BACKUP_DIR/$(dirname "$file")"
            mv "$target" "$DOTFILES_BACKUP_DIR/$file"
            log_warn "Backed up $target → $DOTFILES_BACKUP_DIR/$file"
            ;;
    esac

    target=$(dotfiles_target "$file")
    mkdir -p "$(dirname "$target")"
    ln -sfn "$source" "$target"
    log_info "Linked ~/${target#"$HOME"/} → dotfiles/$file"
}
