#!/usr/bin/env bash
# dmhold-check.sh - inspect dm hold devices vs stale XFS sysfs entries
# Usage:
#   dmhold-check.sh              report only
#   dmhold-check.sh --release    also remove holders that are no longer needed
#   IMG_DIR=/tmp dmhold-check.sh
# Exit codes: 0 = clean, 1 = orphan XFS entries without holder (reboot/holder needed),
#             2 = releasable holders found (report mode) or leftovers
set -uo pipefail

IMG_DIR=${IMG_DIR:-/tmp}
RELEASE=0
[[ ${1:-} == --release ]] && RELEASE=1
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }

hr() { printf '%*s\n' 78 '' | tr ' ' '-'; }

declare -A DM_BY_BLK      # dm-N -> name
declare -A DM_OPEN        # name -> open count
declare -A DM_MINOR       # name -> major:minor
declare -A DM_BLK         # name -> dm-N

while IFS='|' read -r name major minor open blk; do
    [[ -n $name ]] || continue
    DM_BY_BLK[$blk]=$name
    DM_OPEN[$name]=$open
    DM_MINOR[$name]="$major:$minor"
    DM_BLK[$name]=$blk
done < <(dmsetup info -c --noheadings --separator '|' -o name,major,minor,open,blkdevname 2>/dev/null)

mapfile -t XFS_DM < <(ls /sys/fs/xfs 2>/dev/null | grep -E '^dm-[0-9]+$' | sort -V)

rc=0
RELEASABLE=()

# ---------- 1. XFS sysfs entries vs live dm devices ----------
echo "== XFS sysfs entries (/sys/fs/xfs) =="
hr
printf '%-8s %-8s %-55s\n' "ENTRY" "STATE" "DM NAME / NOTE"
hr
ORPHANS=()
for e in "${XFS_DM[@]}"; do
    if [[ -n ${DM_BY_BLK[$e]:-} ]]; then
        n=${DM_BY_BLK[$e]}
        if [[ $n =~ ^dm[0-9]+hold$ ]]; then
            printf '%-8s %-8s %s\n' "$e" "ODD" "$n (holder itself has XFS entry, unexpected)"
        else
            printf '%-8s %-8s %s (open=%s)\n' "$e" "OK" "$n" "${DM_OPEN[$n]}"
        fi
    else
        printf '%-8s %-8s %s\n' "$e" "ORPHAN" "no dm device; leaked XFS superblock/kobject"
        ORPHANS+=("$e")
    fi
done
[[ ${#XFS_DM[@]} -eq 0 ]] && echo "(none)"
echo

# ---------- 2. Holder devices ----------
echo "== Hold devices (dm<N>hold) =="
hr
printf '%-10s %-8s %-6s %-9s %-7s %s\n' "NAME" "DEVNO" "OPEN" "TARGET" "LOOP" "VERDICT"
hr
HOLDERS=0
for name in $(printf '%s\n' "${!DM_OPEN[@]}" | grep -E '^dm[0-9]+hold$' | sort -V); do
    HOLDERS=$((HOLDERS+1))
    want=${name//[!0-9]/}                  # N in dmNhold
    want_blk="dm-$want"
    blk=${DM_BLK[$name]}
    open=${DM_OPEN[$name]}
    mm=${DM_MINOR[$name]}

    # backing loop device
    backing=$(dmsetup table "$name" 2>/dev/null | awk '{print $4}')
    loop="-"
    if [[ -n $backing && -e /sys/dev/block/$backing ]]; then
        loop=$(basename "$(readlink -f "/sys/dev/block/$backing")")
    fi

    if [[ $blk != "$want_blk" ]]; then
        verdict="NAME/MINOR MISMATCH (holds $blk, not $want_blk)"
    elif [[ $open != 0 ]]; then
        verdict="IN USE (open=$open), keep"
    elif [[ -e /sys/fs/xfs/$want_blk ]]; then
        verdict="NEEDED: protects stale /sys/fs/xfs/$want_blk"
    else
        verdict="RELEASABLE: no stale XFS entry for $want_blk"
        RELEASABLE+=("$name")
    fi
    printf '%-10s %-8s %-6s %-9s %-7s %s\n' "$name" "$mm" "$open" "linear" "$loop" "$verdict"
done
[[ $HOLDERS -eq 0 ]] && echo "(no holders)"
echo

# ---------- 3. Orphans without a holder ----------
if [[ ${#ORPHANS[@]} -gt 0 ]]; then
    echo "== Orphan XFS entries =="
    hr
    for e in "${ORPHANS[@]}"; do
        n=${e#dm-}
        if [[ -n ${DM_OPEN[dm${n}hold]:-} ]]; then
            echo "$e: orphan, but dm${n}hold exists (minor protected)"
        else
            echo "$e: orphan and NOT held; a new LV may be assigned this minor -> create: dmhold.sh create dm${n}hold $n"
            rc=1
        fi
    done
    echo
fi

# ---------- 4. Leftover images / loop devices ----------
echo "== Leftover images and loop devices =="
hr
LEFT=0
shopt -s nullglob
for img in "$IMG_DIR"/dm*hold.img; do
    name=$(basename "$img" .img)
    if [[ -z ${DM_OPEN[$name]:-} ]]; then
        loops=$(losetup -j "$img" -O NAME --noheadings | tr '\n' ' ')
        echo "$img: no dm device '$name'; loops: ${loops:-none}"
        LEFT=$((LEFT+1))
    fi
done
shopt -u nullglob
[[ $LEFT -eq 0 ]] && echo "(none)"
echo

# ---------- 5. Release ----------
if [[ ${#RELEASABLE[@]} -gt 0 ]]; then
    echo "== Releasable holders: ${RELEASABLE[*]} =="
    if [[ $RELEASE -eq 1 ]]; then
        for name in "${RELEASABLE[@]}"; do
            img="$IMG_DIR/$name.img"
            backing=$(dmsetup table "$name" | awk '{print $4}')
            loop=""
            [[ -e /sys/dev/block/$backing ]] && loop=/dev/$(basename "$(readlink -f "/sys/dev/block/$backing")")
            dmsetup remove "$name" && echo "removed $name" || { echo "FAILED to remove $name"; continue; }
            [[ -n $loop ]] && losetup -d "$loop" && echo "detached $loop"
            rm -f "$img" && echo "deleted $img"
        done
    else
        echo "Run with --release to remove them."
        [[ $rc -eq 0 ]] && rc=2
    fi
fi

exit $rc
