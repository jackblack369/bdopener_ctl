#!/bin/bash
# find-bd-holder.sh v2 - locate whatever is holding bd_openers on a block device.
#
# Usage: ./find-bd-holder.sh /dev/csi-lvm/pvc-0e64b733-e3e5-4621-b0b4-63f51c4534dd
#        ./find-bd-holder.sh --mount-configfs /dev/csi-lvm/pvc-...
#
# Read-only by default. --mount-configfs is the ONLY state change it will make,
# and only if configfs is not already mounted (mounting it is how you see nvmet
# items that already exist in the kernel).
#
# v2 fixes two v1 defects:
#   * dmsetup -o used an invalid field name ('state'), so the open count was
#     silently never printed
#   * the /proc scan compared st_rdev only, missing a process holding a regular
#     FILE on a filesystem mounted from the LV (the lazy-unmount case). v2
#     matches st_dev as well.
# v2 adds: orphaned-superblock detection, nvmet-without-configfs, nested PV,
#   fd-pinned mount namespaces, stuck udev/D-state, kubelet staging paths,
#   sanlock LV-UUID correlation.
# v2.1 fixes the process scan: %r (st_rdev) is HEX, so bash read it as octal or
#   a bare name and errored ("value too great for base"); some stat builds print
#   '?' for it and crashed (( )) outright. Now reads %R (DECIMAL st_rdev) and
#   validates digits before arithmetic, so a weird stat can't kill the scan.

set -uo pipefail

MOUNT_CONFIGFS=0
if [[ ${1:-} == --mount-configfs ]]; then MOUNT_CONFIGFS=1; shift; fi
DEV="${1:?usage: $0 [--mount-configfs] <block-device-path>}"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
head2(){ printf '\n=== %s ===\n' "$*"; }
hit()  { printf '  >> HOLDER: %s\n' "$*"; }
susp() { printf '  ?? SUSPECT: %s\n' "$*"; }
note() { printf '     %s\n' "$*"; }
# true only when the value is a plain decimal integer -- the only kind safe to
# feed into (( )). %r is hex and some stat builds print '?' for st_rdev.
decdev() { [[ $1 =~ ^[0-9]+$ ]]; }
# Print "st_rdev st_dev" as DECIMAL for path $1, or fail. GNU coreutils %R/%d
# are already decimal; some stat builds (e.g. busybox) print '?' for %R, so
# fall back to %t/%T (hex major/minor) to rebuild st_rdev. st_dev is then
# unknown (0), so on such hosts only direct device-node opens are matched.
devnums() {
    local p=$1 fr d fm fn
    read -r fr d < <(stat -L -c '%R %d' "$p" 2>/dev/null) || return 1
    if decdev "${fr:-}" && decdev "${d:-}"; then
        printf '%s %s\n' "$fr" "$d"
        return 0
    fi
    read -r fm fn < <(stat -L -c '%t %T' "$p" 2>/dev/null) || return 1
    [[ $fm =~ ^[0-9a-fA-F]+$ && $fn =~ ^[0-9a-fA-F]+$ ]] || return 1
    (( MAJ == 0 && MIN == 0 )) && return 1
    printf '%s 0\n' "$(( ((0x$fm & 0xfff) << 8) | (0x$fn & 0xff) | ((0x$fn & ~0xff) << 12) ))"
}

[[ -b $DEV ]] || die "$DEV is not a block special file"
[[ $EUID -eq 0 ]] || die "must run as root (the /proc and dm probes need it)"

REAL=$(readlink -f "$DEV")
read -r MAJ_HEX MIN_HEX < <(stat -L -c '%t %T' "$DEV")
MAJ=$((0x${MAJ_HEX:-0}))
MIN=$((0x${MIN_HEX:-0}))
DEVT="$MAJ:$MIN"
MAPS_DEVT=$(printf '%02x:%02x' "$MAJ" "$MIN")
SYSBLK="/sys/dev/block/$DEVT"
KNAME=$(basename "$(readlink -f "$SYSBLK")" 2>/dev/null || echo '?')

# glibc st_dev encoding: minor in low 8 bits, major next 12, minor>>8 at bit 12.
# A regular file on a fs mounted from this device reports this as st_dev (%d).
STDEV=$(( ((MAJ & 0xfff) << 8) | (MIN & 0xff) | ((MIN & ~0xff) << 12) ))

cat <<EOF
device       : $DEV
resolved     : $REAL
kernel name  : $KNAME
dev_t        : $DEVT   (maps form: $MAPS_DEVT, st_dev decimal: $STDEV)
EOF

FOUND=0
mark() { FOUND=$((FOUND + 1)); hit "$@"; }

# ----------------------------------------------------------- open counters (FIXED)
head2 "open counters"
if [[ $KNAME == dm-* ]] && command -v dmsetup >/dev/null; then
    DMNAME=$(dmsetup info -c --noheadings -o name -j "$MAJ" -m "$MIN" 2>/dev/null)
    note "dm name   : ${DMNAME:-<unknown>}"
    # v1 bug: 'state' is not a valid report field and killed the whole command.
    OPENCNT=$(dmsetup info -c --noheadings -o open -j "$MAJ" -m "$MIN" 2>/dev/null | xargs)
    note "dm open   : ${OPENCNT:-<query failed>}   <-- what makes deactivation return EBUSY"
    note "dm attr   : $(dmsetup info -c --noheadings -o attr -j "$MAJ" -m "$MIN" 2>/dev/null | xargs)"
    note "dm seg/ev : $(dmsetup info -c --noheadings -o segments,events -j "$MAJ" -m "$MIN" 2>/dev/null | xargs)"
    note "dm table  : $(dmsetup table -j "$MAJ" -m "$MIN" 2>/dev/null | xargs)"
fi
[[ -r $SYSBLK/inflight ]] && note "inflight  : $(cat "$SYSBLK/inflight")"
if command -v lvs >/dev/null; then
    LVINFO=$(lvs --noheadings -o vg_name,lv_name,lv_uuid,lv_attr,lv_device_open \
             "$DEV" 2>/dev/null | xargs)
    note "lvs       : $LVINFO"
    LV_UUID=$(awk '{print $3}' <<<"$LVINFO")
    VG_NAME=$(awk '{print $1}' <<<"$LVINFO")
fi

# ------------------------------------------------ ORPHANED SUPERBLOCK (new, key)
head2 "live filesystem superblock on $KNAME (survives lazy unmount)"
SB=0
for fs in ext4 ext3 xfs btrfs f2fs; do
    if [[ -d /sys/fs/$fs/$KNAME ]]; then
        SB=1
        mark "a live $fs superblock exists at /sys/fs/$fs/$KNAME"
        note "The filesystem is still MOUNTED-OR-ORPHANED in the kernel. If no"
        note "mountpoint exists, it was lazily unmounted (umount -l) while a file"
        note "was still open: the superblock keeps the bdev open with no visible"
        note "mount and, if the opener has since exited, no visible process."
    fi
done
if compgen -G "/proc/fs/jbd2/${KNAME}-*" >/dev/null; then
    SB=1; mark "active jbd2 journal: $(ls -d /proc/fs/jbd2/${KNAME}-* 2>/dev/null | xargs)"
fi
((SB)) || note "no live superblock for this device"

# --------------------------------------------------- NVMET even without configfs
head2 "NVMe-oF target (nvmet)"
note "nvmet modules loaded: $(lsmod 2>/dev/null | awk '$1 ~ /^nvmet/ {printf "%s ", $1}' || echo none)"
note "nvme host  modules  : $(lsmod 2>/dev/null | awk '$1 ~ /^nvme_(tcp|rdma|fc)/ {printf "%s ", $1}' || echo none)"

CFGMNT=$(awk '$3=="configfs" {print $2}' /proc/self/mounts | head -1)
if [[ -z $CFGMNT && $MOUNT_CONFIGFS -eq 1 ]]; then
    note "configfs not mounted; mounting at /sys/kernel/config to reveal items"
    mkdir -p /sys/kernel/config
    mount -t configfs none /sys/kernel/config && CFGMNT=/sys/kernel/config \
        || note "mount failed"
fi

if [[ -z $CFGMNT ]]; then
    if lsmod 2>/dev/null | grep -q '^nvmet'; then
        susp "nvmet IS loaded but configfs is NOT mounted."
        note "Unmounting configfs hides existing nvmet items; it does not destroy"
        note "them. Namespaces may still be holding this LV open right now and"
        note "this probe cannot see them. Re-run with --mount-configfs, or:"
        note "    mount -t configfs none /sys/kernel/config"
        note "    grep -r . /sys/kernel/config/nvmet/subsystems/*/namespaces/*/device_path"
    else
        note "configfs not mounted and no nvmet module: target side not in use here"
    fi
else
    note "configfs at $CFGMNT"
    NVMET="$CFGMNT/nvmet"
    if [[ -d $NVMET ]]; then
        shopt -s nullglob
        any=0
        for ns in "$NVMET"/subsystems/*/namespaces/*; do
            dp=$(cat "$ns/device_path" 2>/dev/null) || continue
            [[ -z $dp ]] && continue
            nsreal=$(readlink -f "$dp" 2>/dev/null || echo "$dp")
            if [[ $nsreal == "$REAL" || $dp == "$DEV" ]]; then
                any=1
                sub=$(basename "$(dirname "$(dirname "$ns")")")
                mark "nvmet namespace $sub/$(basename "$ns") -> $dp (enable=$(cat "$ns/enable" 2>/dev/null))"
                note "This is a real kernel-context reference: +1 bd_openers,"
                note "invisible to lsof/fuser, no mountpoint. Release it properly:"
                note "    echo 0 > $ns/enable"
                note "    rmdir $ns"
            fi
        done
        # also report every namespace, so a stale path that no longer resolves
        # to this LV but was created for this PVC is still visible
        for ns in "$NVMET"/subsystems/*/namespaces/*; do
            dp=$(cat "$ns/device_path" 2>/dev/null) || continue
            case "$dp" in
              *"$(basename "$DEV")"*) susp "namespace path mentions this PVC by name: $ns -> $dp";;
            esac
        done
        shopt -u nullglob
        ((any)) || note "no enabled namespace resolves to this device"
    else
        note "$NVMET absent: nvmet not configured"
    fi
fi

# ------------------------------------------------------------- stacked / nested
head2 "sysfs holders, dm tables, nested PV"
if compgen -G "$SYSBLK/holders/*" >/dev/null; then
    for h in "$SYSBLK"/holders/*; do mark "upper device /dev/$(basename "$h")"; done
else
    note "holders: none"
fi
if command -v dmsetup >/dev/null; then
    M=$(dmsetup table 2>/dev/null | grep -F "$DEVT" || true)
    [[ -n $M ]] && while IFS= read -r l; do mark "dm table: $l"; done <<<"$M" \
                || note "dm tables referencing $DEVT: none"
fi
if command -v pvs >/dev/null; then
    P=$(pvs --noheadings -o pv_name,vg_name "$REAL" 2>/dev/null | xargs)
    [[ -n $P ]] && susp "device is itself an LVM PV (nested VG): $P" \
                || note "not a nested PV"
fi

# ------------------------------------------------------- loop/md/swap/bcache/dm
head2 "loop / md / swap / bcache"
command -v losetup >/dev/null && { L=$(losetup -a 2>/dev/null | grep -F "$REAL" || true); \
    [[ -n $L ]] && mark "loop: $L" || note "loop: none"; }
shopt -s nullglob
for s in /sys/block/md*/slaves/*; do
    [[ $(basename "$s") == "$KNAME" ]] && mark "md: $(basename "$(dirname "$(dirname "$s")")")"
done
shopt -u nullglob
grep -qF "$REAL" /proc/swaps 2>/dev/null && mark "swap: $(grep -F "$REAL" /proc/swaps)" || note "swap: none"
[[ -d /sys/block/$KNAME/bcache ]] && mark "bcache member" || note "bcache: none"

# ------------------------------------------------------------ mounts, all ns
head2 "mounts referencing $DEVT (per-process namespaces)"
any=0
for mi in /proc/[0-9]*/mountinfo; do
    [[ -r $mi ]] || continue
    while read -r _ _ mm rest; do
        [[ $mm == "$DEVT" ]] || continue
        pid=$(cut -d/ -f3 <<<"$mi"); any=1
        mark "pid $pid ($(cat /proc/"$pid"/comm 2>/dev/null)): $rest"
    done <"$mi"
done
((any)) || note "none"

# ------------------------------- fd-pinned mount namespaces (no process at all)
head2 "mount namespaces pinned by an fd (invisible to the scan above)"
NSFD=0
for l in /proc/[0-9]*/fd/*; do
    [[ -L $l ]] || continue
    tgt=$(readlink "$l" 2>/dev/null) || continue
    [[ $tgt == nsfs:* ]] || continue
    if out=$(nsenter --mnt="$l" -- cat /proc/self/mountinfo 2>/dev/null); then
        if grep -q " $DEVT " <<<"$out"; then
            NSFD=1
            pid=$(cut -d/ -f3 <<<"$l")
            mark "leaked mount ns pinned by pid $pid ($(cat /proc/"$pid"/comm 2>/dev/null)) fd $(basename "$l") still mounts $DEVT"
            note "fix: nsenter --mnt=$l umount <target>   (or kill the pinning fd holder)"
        fi
    fi
done
((NSFD)) || note "none found (nsenter may fail for namespaces lacking /bin/cat)"

# ----------------------------- process refs: st_rdev AND st_dev (v1 missed st_dev)
head2 "process references (matches both device-node fds and open files on the fs)"
any=0
BADSTAT=0
for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    comm=$(cat "$p/comm" 2>/dev/null) || continue

    for l in "$p"/fd/*; do
        [[ -e $l ]] || continue
        read -r frdev fdev < <(devnums "$l") || { BADSTAT=$((BADSTAT + 1)); continue; }
        if (( frdev == STDEV )); then
            any=1; mark "pid $pid ($comm) fd $(basename "$l") -> the BLOCK DEVICE $(readlink "$l")"
        elif (( fdev == STDEV )); then
            any=1; mark "pid $pid ($comm) fd $(basename "$l") -> FILE on the fs: $(readlink "$l")"
            note "an open file keeps the superblock, and thus the bdev, alive"
        fi
    done

    if [[ -r $p/maps ]] && grep -q " $MAPS_DEVT " "$p/maps" 2>/dev/null; then
        any=1; mark "pid $pid ($comm) has a file from this device mmap'd"
    fi
    for sp in cwd root exe; do
        read -r srdev sdev < <(devnums "$p/$sp") || { BADSTAT=$((BADSTAT + 1)); continue; }
        if (( srdev == STDEV || sdev == STDEV )); then
            any=1; mark "pid $pid ($comm) $sp is on this device"
        fi
    done
done
((any)) || note "no process reference of either kind"
((BADSTAT)) && note "note: $BADSTAT fd/path(s) skipped -- stat returned a non-numeric device value"
((BADSTAT)) && note "      (its %R/%d fields are not readable; that layer is blind on this host)"

# ------------------------------------------------------ udev / stuck kernel work
head2 "udev and stuck tasks"
note "D-state tasks: $(ps -eo stat,pid,comm --no-headers 2>/dev/null | awk '$1 ~ /^D/ {printf "%s(%s) ", $3, $2}' || true)"
command -v udevadm >/dev/null && note "udev queue: $(udevadm settle --timeout=5 && echo settled || echo 'STILL BUSY')"

# ---------------------------------------------------------------- k8s leftovers
head2 "kubelet / CSI staging leftovers for this PVC"
PVC=$(basename "$DEV")
FOUNDK=0
for base in /var/lib/kubelet/pods /var/lib/kubelet/plugins; do
    [[ -d $base ]] || continue
    while IFS= read -r hitpath; do
        FOUNDK=1; susp "stale path: $hitpath"
    done < <(find "$base" -maxdepth 8 -name "*${PVC#pvc-}*" 2>/dev/null | head -20)
done
((FOUNDK)) || note "no kubelet path mentions ${PVC}"
command -v findmnt >/dev/null && \
    note "findmnt: $(findmnt -rno TARGET,SOURCE | grep -F "$PVC" | head -5 || echo none)"

# ------------------------------------------------------------ sanlock / lvmlockd
head2 "sanlock / lvmlockd correlation"
if command -v sanlock >/dev/null; then
    EXUUID=$(sanlock client status 2>/dev/null | awk '/^r lvm_/{split($2,a,":"); print a[2]}')
    note "sanlock resource leases held (LV UUIDs): ${EXUUID:-none}"
    if [[ -n ${LV_UUID:-} ]]; then
        note "this LV's UUID              : $LV_UUID"
        if grep -qF "$LV_UUID" <<<"${EXUUID:-}"; then
            susp "lvmlockd holds an EXCLUSIVE sanlock lease on THIS LV."
            note "That is a lock-manager reference, NOT bd_openers. It makes"
            note "deactivation fail with a locking error rather than EBUSY. If that"
            note "is your actual error, the fix is lvmlockd-side:"
            note "    lvmlockctl -i                       # inspect"
            note "    lvchange -an $VG_NAME/$(basename "$DEV")"
            note "    lvmlockctl --drop $VG_NAME          # only if VG is unused cluster-wide"
        else
            note "the held lease is for a DIFFERENT LV; not your blocker"
        fi
    fi
fi

# ------------------------------------------------------------------- verdict
head2 "verdict"

# A live superblock or a non-zero bd_holders means the reference is OWNED, not
# leaked. This is a hard gate: forcing the count down in this state leaves a
# live consumer submitting I/O to a device the kernel thinks is idle, and the
# next real blkdev_put() underflows the counter. The observable symptom of
# having done it anyway is a mount that fails with
#   fsconfig() failed: File exists
# because the zombie superblock still owns /sys/fs/<fs>/<kname>. Only a reboot
# clears that.
if (( SB )); then
    printf '  *** DO NOT RELEASE ***\n'
    printf '  A live filesystem superblock exists for %s.\n' "$KNAME"
    printf '  The bd_openers reference is OWNED by that superblock, not leaked.\n\n'
    printf '  Forcing it down will NOT let you remount. It leaves a zombie\n'
    printf '  superblock, and the next mount fails with:\n'
    printf '      fsconfig() failed: File exists\n'
    printf '  (sysfs: cannot create duplicate filename /fs/<fs>/%s in dmesg)\n' "$KNAME"
    printf '  Only a node reboot clears that state.\n\n'
    printf '  Do this instead:\n'
    printf '    1. findmnt -A -S %s        # find the mount, anywhere\n' "$DEV"
    printf '    2. lsns -t mnt                  # NPROCS=0 + holder PID = fd-pinned\n'
    printf '    3. umount it properly, or delete the pod/container pinning the ns\n'
    printf '    4. if the mount is unreachable: drain + reboot the node\n'
elif (( FOUND == 0 )); then
    cat <<'EOF'
  No holder found. Before forcing anything, exhaust these:
    1. Re-run with --mount-configfs if nvmet is loaded (see nvmet section).
    2. dmsetup remove --deferred <name>    # auto-removes when count drops
    3. dmsetup remove --force  <name>      # error target, then remove
    4. Compare dm 'open' above with the module's bd_openers reading:
         insmod bdopener_ctl.ko; echo 'inspect <dev>' > /proc/bdopener_ctl
       If dm open == 0 but bd_openers > 0, only the bdev counter is stale.

  Note: "no holder found" is not proof of a leak. This scan is blind to a
  holder in a mount namespace no live process exposes (and silently blind
  entirely if nsenter is missing). The module's own bd_holders check is the
  backstop -- if it refuses, believe it over this verdict.
EOF
else
    printf '  %d holder(s) identified. Release them at their own layer.\n' "$FOUND"
    printf '  Do NOT force-decrement bd_openers while a real holder exists.\n'
fi
