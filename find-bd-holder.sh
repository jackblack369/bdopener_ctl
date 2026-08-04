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
# feed into (( )). Some stat builds print '?' or a literal '%r' for st_rdev.
decdev() { [[ $1 =~ ^[0-9]+$ ]]; }
hexdev() { [[ $1 =~ ^[0-9a-fA-F]+$ ]]; }
#
# How path $1 relates to the target device. Echoes rdev | dev | none.
#
#   rdev -> an open fd on the BLOCK DEVICE NODE itself
#   dev  -> an open FILE on a filesystem mounted from it (the lazy-unmount case)
#
# v2.2: the v2/v2.1 version required BOTH fields to be plain decimal and bailed
# otherwise. On GNU coreutils %R is st_rdev in HEX (dm-9 prints "fd09"), so the
# digit test failed on every path, the usable decimal %d was discarded with it,
# and the whole scan silently reported thousands of "skipped" -- i.e. the check
# that decides "recoverable" vs "must reboot" never actually ran.
#
# Which of %r/%R is decimal has varied across coreutils versions, so trust
# neither: accept a match on ANY plausible reading of st_rdev, evaluate st_dev
# independently, and never let one unreadable field abort the other.
devkind() {
    local p=$1 R d r n
    read -r R d r < <(stat -L -c '%R %d %r' "$p" 2>/dev/null) || return 1
    for n in "${R:-}" "${r:-}"; do
        [[ -n $n ]] || continue
        # 10#/16# prefixes are mandatory: a zero-padded value would otherwise
        # be read as octal, and a hex one would abort (( )) with a syntax error.
        decdev "$n" && (( 10#$n == STDEV ))   && { printf 'rdev\n'; return 0; }
        hexdev "$n" && (( 16#$n == STDEV ))   && { printf 'rdev\n'; return 0; }
    done
    decdev "${d:-}" || return 1
    (( 10#$d == STDEV )) && { printf 'dev\n'; return 0; }
    printf 'none\n'
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
FSTYPE_SB=""
for fs in ext4 ext3 xfs btrfs f2fs; do
    if [[ -d /sys/fs/$fs/$KNAME ]]; then
        SB=1
        FSTYPE_SB=$fs
        mark "a live $fs superblock exists at /sys/fs/$fs/$KNAME"
        note "The filesystem is still MOUNTED-OR-ORPHANED in the kernel. If no"
        note "mountpoint exists, it was lazily unmounted (umount -l) while a file"
        note "was still open: the superblock keeps the bdev open with no visible"
        note "mount and, if the opener has since exited, no visible process."
    fi
done
if compgen -G "/proc/fs/jbd2/${KNAME}-*" >/dev/null; then
    SB=1; FSTYPE_SB=${FSTYPE_SB:-ext4}
    mark "active jbd2 journal: $(ls -d /proc/fs/jbd2/${KNAME}-* 2>/dev/null | xargs)"
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
MOUNTED=0
for mi in /proc/[0-9]*/mountinfo; do
    [[ -r $mi ]] || continue
    while read -r _ _ mm rest; do
        [[ $mm == "$DEVT" ]] || continue
        pid=$(cut -d/ -f3 <<<"$mi"); MOUNTED=1
        mark "pid $pid ($(cat /proc/"$pid"/comm 2>/dev/null)): $rest"
    done <"$mi"
done
((MOUNTED)) || note "none"

# ------------------------------- fd-pinned mount namespaces (no process at all)
head2 "mount namespaces pinned by an fd or a bind mount (invisible to the scan above)"
NSFD=0
NSSKIP=0
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
# A BIND-pinned namespace (snapd's /run/snapd/ns/*.mnt, `mount --bind` of
# /proc/<pid>/ns/mnt) has no fd and no process, so it is absent from both the
# loop above AND from `lsns`. findmnt is the only thing that lists them.
if command -v findmnt >/dev/null; then
    while read -r tgt; do
        [[ -n $tgt ]] || continue
        if out=$(nsenter --mount="$tgt" -- cat /proc/self/mountinfo 2>/dev/null); then
            if grep -q " $DEVT " <<<"$out"; then
                NSFD=1
                mark "bind-pinned mount ns at $tgt still mounts $DEVT"
                note "fix: nsenter --mount=$tgt umount <target>"
            fi
        else
            # Expected for the common case: net/uts/ipc namespaces are also
            # nsfs, and --mount rejects them. Only worth reporting in bulk.
            NSSKIP=$((NSSKIP + 1))
        fi
    done < <(findmnt -rno TARGET,FSTYPE 2>/dev/null | awk '$2=="nsfs"{print $1}')
fi
((NSSKIP)) && note "$NSSKIP pinned nsfs entr(ies) were not mount namespaces (net/uts/ipc) - not applicable"
((NSFD)) || note "none found (nsenter may fail for namespaces lacking /bin/cat)"

# ----------------------------- process refs: st_rdev AND st_dev (v1 missed st_dev)
head2 "process references (matches both device-node fds and open files on the fs)"
any=0
BADSTAT=0
FDPIN=0   # a process holds the fs open => the superblock is REACHABLE, no reboot
for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    comm=$(cat "$p/comm" 2>/dev/null) || continue

    for l in "$p"/fd/*; do
        [[ -e $l ]] || continue
        k=$(devkind "$l") || { BADSTAT=$((BADSTAT + 1)); continue; }
        case $k in
          rdev) any=1; mark "pid $pid ($comm) fd $(basename "$l") -> the BLOCK DEVICE $(readlink "$l")";;
          dev)  any=1; mark "pid $pid ($comm) fd $(basename "$l") -> FILE on the fs: $(readlink "$l")"
                note "an open file keeps the superblock, and thus the bdev, alive"
                note "closing it (or killing this pid) retires the superblock -- no reboot needed"
                FDPIN=1;;
        esac
    done

    if [[ -r $p/maps ]] && grep -q " $MAPS_DEVT " "$p/maps" 2>/dev/null; then
        any=1; mark "pid $pid ($comm) has a file from this device mmap'd"
    fi
    for sp in cwd root exe; do
        k=$(devkind "$p/$sp") || { BADSTAT=$((BADSTAT + 1)); continue; }
        if [[ $k != none ]]; then
            any=1; mark "pid $pid ($comm) $sp is on this device"
            FDPIN=1
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
    printf '  (sysfs: cannot create duplicate filename /fs/<fs>/%s in dmesg)\n\n' "$KNAME"

    # The whole point of the st_dev scan: a superblock kept alive by a process
    # is REACHABLE, so this is repairable in place. One with no mount, no fd and
    # no namespace has no userspace handle at all -- umount needs a mountpoint,
    # xfs_io -c shutdown needs a mount path, and the fs sysfs dir exposes stats
    # and error knobs only. Nothing can retire it, hence the reboot.
    if (( MOUNTED || FDPIN || NSFD )); then
        printf '  RECOVERABLE IN PLACE -- a live handle to it was found above.\n'
        printf '  No reboot needed. Retire the superblock through that handle:\n'
        printf '    * mount listed        -> umount it (add -f if the backing store is gone)\n'
        printf '    * open file / cwd     -> close the fd, or kill the pid shown\n'
        printf '    * fd-pinned namespace -> nsenter --mnt=<fd> umount <target>\n'
        printf '  Then re-run this script: the superblock and the count both go away.\n'
    else
        printf '  NO HANDLE FOUND by this scan -- but note what that does and does\n'
        printf '  not prove. /sys/fs/%s/%s is removed by ->kill_sb(), which runs as\n' "$FSTYPE_SB" "$KNAME"
        printf '  soon as s_active hits 0. Its existence therefore PROVES a reference\n'
        printf '  is still held. A superblock held by nothing cannot exist, so this\n'
        printf '  is a scan limit, not a verdict.\n\n'
        printf '  Escalate before reaching for a reboot:\n'
        printf '    sudo ./unwedge-xfs-sb.sh --apply %s\n\n' "$DEV"
        printf '  It covers what this scan cannot: bind-pinned namespaces (no fd, no\n'
        printf '  process -- invisible to lsns too), and D-state holders that ignore\n'
        printf '  SIGKILL until their stuck I/O is aborted.\n'
        printf '  Reboot only if that also comes up empty. LV data is intact either way.\n'
        (( BADSTAT )) && printf '\n  CAVEAT: %d path(s) were skipped above, so "no fd" is unproven\n' "$BADSTAT"
        (( BADSTAT )) && printf '  on this host. Resolve that first -- it is the check that decides\n'
        (( BADSTAT )) && printf '  recoverable-vs-reboot.\n'
    fi
    printf '\n  Either way: do NOT use force_holder=1. The holder is real.\n'
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
