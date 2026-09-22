#!/bin/sh
# pig installer (user-local, no sudo, no system files).
# Usage:
#   sh install.sh [--force]            install pig into ~/.local/bin
#   sh install.sh --uninstall [--force]
# --force skips the distribution check (own responsibility).
#
# Copyright (c) 2026 @blvcksyxx (https://github.com/blvcksyxx/pig)
# Licensed under PolyForm Noncommercial 1.0.0 (see LICENSE).
set -u

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SRC_DIR/pig.py"

MARK_BEGIN="# >>> pig installer >>>"
MARK_END="# <<< pig installer <<<"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

die() {
    echo "pig installer: error: $1" >&2
    exit 1
}

# Home of the invoking user (works when run under sudo too).
target_home() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "$(id -un 2>/dev/null || echo root)" ]; then
        _h="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
        if [ -n "$_h" ] && [ -d "$_h" ]; then
            printf '%s' "$_h"
            return
        fi
    fi
    printf '%s' "${HOME:-$(echo ~)}"
}

fix_owner() {
    if [ -n "${SUDO_USER:-}" ]; then
        chown "$SUDO_USER" "$1" 2>/dev/null || true
    fi
}

add_path_once() {
    # add_path_once <rcfile>: append PATH block unless already present
    if grep -qF "$MARK_BEGIN" "$1" 2>/dev/null; then
        return 1
    fi
    {
        echo "$MARK_BEGIN"
        echo "$PATH_LINE"
        echo "$MARK_END"
    } >>"$1"
    fix_owner "$1"
    return 0
}

remove_path_block() {
    # remove_path_block <rcfile>: delete our PATH block, if present
    if ! grep -qF "$MARK_BEGIN" "$1" 2>/dev/null; then
        return 1
    fi
    _tmp="$1.pig-tmp-$$"
    sed "/$MARK_BEGIN/,/$MARK_END/d" "$1" >"$_tmp" && cat "$_tmp" >"$1"
    rm -f "$_tmp"
    fix_owner "$1"
    return 0
}

# do_install [--force]: FORCE=1 skips the distro gate (own responsibility)
do_install() {
    [ -f "$SRC" ] || die "pig executable not found next to install.sh ($SRC)"
    command -v python3 >/dev/null 2>&1 || die "python3 is required"

    if ! python3 "$SRC" doctor; then
        if [ "${FORCE:-0}" != "1" ]; then
            die "unsupported distribution (see DISTROS.md). Rerun with --force at your own responsibility."
        fi
        echo "warning: unsupported distribution, continuing with --force."
        echo "You take responsibility for your own system."
    fi

    H="$(target_home)"
    [ -n "$H" ] && [ -d "$H" ] || die "cannot determine home directory"

    mkdir -p "$H/.local/bin" "$H/.config/pig" "$H/.cache/pig" || die "cannot create directories in $H"
    cp "$SRC" "$H/.local/bin/pig" || die "cannot copy pig to $H/.local/bin"
    chmod 755 "$H/.local/bin/pig" || die "cannot chmod $H/.local/bin/pig"
    fix_owner "$H/.local/bin/pig"

    # init config through pig itself
    if [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" "$H/.local/bin/pig" config >/dev/null || die "pig config failed"
    else
        HOME="$H" "$H/.local/bin/pig" config >/dev/null || die "pig config failed"
    fi

    _added=""
    for _rc in "$H/.bashrc" "$H/.zshrc"; do
        if [ -f "$_rc" ] && add_path_once "$_rc"; then
            _added="$_added $_rc"
        fi
    done

    echo "pig installed to $H/.local/bin/pig"
    if [ -n "$_added" ]; then
        echo "added ~/.local/bin to PATH in:$_added"
        echo "restart your shell or run: export PATH=\"\$HOME/.local/bin:\$PATH\""
    else
        case ":${PATH:-}:" in
            *":$H/.local/bin:"*) echo "~/.local/bin is already in PATH" ;;
            *) echo "add this to your shell rc: $PATH_LINE" ;;
        esac
    fi
    echo "try: pig install postman"
}

do_uninstall() {
    H="$(target_home)"
    [ -n "$H" ] && [ -d "$H" ] || die "cannot determine home directory"

    # the binary itself
    if [ -e "$H/.local/bin/pig" ]; then
        rm -f "$H/.local/bin/pig" && echo "removed $H/.local/bin/pig"
    else
        echo "no $H/.local/bin/pig found"
    fi

    # temp/cache service files (dict cache, staging leftovers); keeps
    # installed.json, config, installed apps, launchers and PATH choice
    # for explicit user action only
    if [ -d "$H/.cache/pig" ]; then
        find "$H/.cache/pig" -mindepth 1 -maxdepth 1 \
            \( -name '.*' -o -name 'pig-*' -o -name 'pig.new-*' \) \
            -exec rm -rf {} + 2>/dev/null
        rmdir "$H/.cache/pig/dicts" 2>/dev/null || true
        echo "cleaned temp files in $H/.cache/pig"
    fi

    for _rc in "$H/.bashrc" "$H/.zshrc"; do
        if [ -f "$_rc" ] && remove_path_block "$_rc"; then
            echo "removed PATH block from $_rc"
        fi
    done

    echo "kept (remove explicitly if wanted):"
    echo "  $H/.config/pig (dictionaries config)"
    echo "  $H/.cache/pig/installed.json (install records)"
    echo "  $H/.local/opt (installed applications)"
    echo "  $H/.local/bin launchers"
    echo "pig uninstalled"
}

# Usage:
#   sh install.sh [--force]            install pig into ~/.local/bin
#   sh install.sh --uninstall [--force]
#
FORCE=0
ACTION="install"
for _arg in "$@"; do
    case "$_arg" in
        --force) FORCE=1 ;;
        --uninstall) ACTION="uninstall" ;;
        install) ACTION="install" ;;
        -h|--help) echo "usage: sh install.sh [--uninstall] [--force]"; exit 0 ;;
        *) die "unknown argument: $_arg (see: sh install.sh --help)" ;;
    esac
done

case "$ACTION" in
    uninstall) do_uninstall ;;
    *) do_install ;;
esac
