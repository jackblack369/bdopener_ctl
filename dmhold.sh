#!/usr/bin/env bash
# dmhold.sh - hold / release a device-mapper minor number with a tiny loop-backed dm device
# Usage:
#   dmhold.sh create <name> [minor]     e.g. dmhold.sh create dm6hold 6
#   dmhold.sh remove <name>             e.g. dmhold.sh remove dm6hold
#   dmhold.sh status <name>
set -euo pipefail

IMG_DIR=${IMG_DIR:-/tmp}
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }

usage() { sed -n '2,6p' "$0"; exit 1; }
die()   { echo "ERROR: $*" >&2; exit 1; }

cmd=${1:-}; name=${2:-}; minor=${3:-}
[[ -n $cmd && -n $name ]] || usage
img="$IMG_DIR/$name.img"

dm_exists() { dmsetup info "$name" &>/dev/null; }

do_status() {
    dmsetup info -C -o name,major,minor,open "$name"
}

do_create() {
    dm_exists && die "dm device '$name' already exists"

    # If a specific minor was requested, make sure it is free
    local dm_major opts=()
    if [[ -n $minor ]]; then
        [[ $minor =~ ^[0-9]+$ ]] || die "minor must be a number"
        dm_major=$(awk '$2=="device-mapper"{print $1}' /proc/devices)
        [[ -n $dm_major ]] || die "cannot find device-mapper major"
        if [[ -e /sys/dev/block/$dm_major:$minor ]]; then
            die "minor $dm_major:$minor is already in use"
        fi
        opts=(--major "$dm_major" --minor "$minor")
    fi

    truncate -s 1M "$img"

    local loop
    loop=$(losetup -f --show "$img")

    # Roll back loop device and image if dmsetup fails
    if ! echo "0 2048 linear $loop 0" | dmsetup create "$name" "${opts[@]}"; then
        losetup -d "$loop" || true
        rm -f "$img"
        die "dmsetup create failed, rolled back"
    fi

    echo "created $name on $loop (image: $img)"
    do_status
}

do_remove() {
    # Find loop devices attached to this image before removing the dm device
    local loops=()
    if [[ -f $img ]]; then
        mapfile -t loops < <(losetup -j "$img" -O NAME --noheadings)
    fi

    if dm_exists; then
        local open
        open=$(dmsetup info -C --noheadings -o open "$name" | tr -d ' ')
        [[ $open == 0 ]] || die "'$name' is open ($open), refusing to remove"
        dmsetup remove "$name"
        echo "removed dm device $name"
    else
        echo "dm device '$name' not present, skipping"
    fi

    local l
    for l in "${loops[@]}"; do
        [[ -n $l ]] || continue
        losetup -d "$l" && echo "detached $l"
    done

    rm -f "$img" && echo "deleted $img"
}

case $cmd in
    create) do_create ;;
    remove) do_remove ;;
    status) do_status ;;
    *)      usage ;;
esac
