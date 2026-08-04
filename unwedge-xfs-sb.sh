#!/bin/bash
# unwedge-xfs-sb.sh - retire an orphaned XFS superblock so its LV can be
# remounted on the SAME node, without a reboot.
#
# Usage:
#   ./unwedge-xfs-sb.sh /dev/csi-lvm/pvc-...          # report only (default)
#   ./unwedge-xfs-sb.sh --apply /dev/csi-lvm/pvc-...  # act
#
# The symptom this fixes:
#   mount: ... fsconfig() failed: File exists
#   dmesg: sysfs: cannot create duplicate filename '/fs/xfs/dm-N'
#
# WHY NO REBOOT IS NEEDED
# -----------------------
# /sys/fs/xfs/<disk> is created by xfs_mountfs() and removed by ->kill_sb(),
# which runs the instant the superblock's s_active reaches 0. So the directory
# existing PROVES s_active > 0, which proves some reference is still held --
# a mount table entry, an open fd, a cwd/root, or a pinned namespace. There is
# no such thing as a superblock held by nothing. "Reboot is the only option"
# always really means "I did not find the holder" or "the holder would not die".
# This script attacks both, in increasing order of force.
#
# It NEVER writes to the filesystem and NEVER destroys the LV. The most
# invasive thing it does is SIGKILL processes and force-shutdown the XFS log,
# both of which affect in-flight writes only, not data at rest.

set -uo pipefail

APPLY=0
[[ ${1:-} == --apply ]] && { APPLY=1; shift; }
DEV="${1:?usage: $0 [--apply] <block-device-path>}"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
head2(){ printf '\n=== %s ===\n' "$*"; }
note() { printf '     %s\n' "$*"; }
act()  { printf '  >> %s\n' "$*"; }
# Run a command, or just print it when not in --apply mode.
run()  {
    if (( APPLY )); then
        act "RUN: $*"
        "$@" && note "ok" || note "FAILED (rc=$?) - continuing"
    else
        act "WOULD RUN: $*"
    fi
}

[[ -b $DEV ]] || die "$DEV is not a block special file"
[[ $EUID -eq 0 ]] || die "must run as root"

# mountinfo octal-escapes space, tab, newline and backslash in the mount point.
# Passing the raw field to umount would look for a path containing a literal
# backslash. Kubelet paths are usually clean, but subPath names are not always.
unesc() {
    local s=$1
    s=${s//\\040/ }; s=${s//\\011/$'\t'}
    s=${s//\\012/$'\n'}; s=${s//\\134/\\}
    printf '%s' "$s"
}

read -r MAJ_HEX MIN_HEX < <(stat -L -c '%t %T' "$DEV")
MAJ=$((0x${MAJ_HEX:-0})); MIN=$((0x${MIN_HEX:-0}))
DEVT="$MAJ:$MIN"
KNAME=$(basename "$(readlink -f "/sys/dev/block/$DEVT")" 2>/dev/null || echo '?')
STDEV=$(( ((MAJ & 0xfff) << 8) | (MIN & 0xff) | ((MIN & ~0xff) << 12) ))

# Which filesystem type owns the stale sysfs entry, if any.
FSTYPE=""
for fs in xfs ext4 ext3 btrfs f2fs; do
    [[ -d /sys/fs/$fs/$KNAME ]] && { FSTYPE=$fs; break; }
done

cat <<EOF
device   : $DEV
kname    : $KNAME    dev_t: $DEVT    st_dev: $STDEV
sysfs sb : ${FSTYPE:+/sys/fs/$FSTYPE/$KNAME}${FSTYPE:-<none - nothing to unwedge>}
mode     : $( ((APPLY)) && echo 'APPLY (will make changes)' || echo 'REPORT ONLY (pass --apply to act)')
EOF

if [[ -z $FSTYPE ]]; then
    head2 "nothing to do"
    note "No live superblock for $KNAME. If mounting still fails, the cause is"
    note "elsewhere -- re-check the exact errno and dmesg."
    exit 0
fi

# ---------------------------------------------------------------------------
# STEP 1: mount table entries, in every namespace.
# Cheapest possible fix: if a mount is listed anywhere, umount retires the sb.
# ---------------------------------------------------------------------------
head2 "step 1 - mount table entries in any namespace"
S1=0
declare -A SEEN_NS=()
for mi in /proc/[0-9]*/mountinfo; do
    [[ -r $mi ]] || continue
    pid=$(cut -d/ -f3 <<<"$mi")
    # One representative pid per distinct mount namespace is enough; entering
    # the same ns once per process would be thousands of redundant nsenters.
    nsid=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null) || continue
    [[ -n ${SEEN_NS[$nsid]:-} ]] && continue
    SEEN_NS[$nsid]=$pid
    while read -r _ _ mm _ mp _; do
        [[ $mm == "$DEVT" ]] || continue
        S1=1
        mp=$(unesc "$mp")
        act "mount at '$mp' in ns $nsid (via pid $pid $(cat /proc/"$pid"/comm 2>/dev/null))"
        # -l detaches even with busy children; the sb still dies once refs drop.
        run nsenter --target "$pid" --mount -- umount "$mp"
    done <"$mi"
done
((S1)) || note "none"

# ---------------------------------------------------------------------------
# STEP 2: pinned namespaces with no live process.
# fd-pinned (nsfs fd in some /proc/*/fd) or bind-pinned (snapd-style
# /run/snapd/ns/*.mnt). Both are invisible to `lsns` and to step 1.
# ---------------------------------------------------------------------------
head2 "step 2 - pinned mount namespaces (no process, invisible to lsns)"
S2=0
for l in /proc/[0-9]*/fd/*; do
    [[ -L $l ]] || continue
    [[ $(readlink "$l" 2>/dev/null) == nsfs:* ]] || continue
    out=$(nsenter --mount="$l" -- cat /proc/self/mountinfo 2>/dev/null) || continue
    while read -r _ _ mm _ mp _; do
        [[ $mm == "$DEVT" ]] || continue
        S2=1
        mp=$(unesc "$mp")
        act "fd-pinned ns $l mounts $DEVT at '$mp'"
        run nsenter --mount="$l" -- umount -l "$mp"
    done <<<"$out"
done
if command -v findmnt >/dev/null; then
    while read -r tgt; do
        [[ -n $tgt ]] || continue
        out=$(nsenter --mount="$tgt" -- cat /proc/self/mountinfo 2>/dev/null) || continue
        while read -r _ _ mm _ mp _; do
            [[ $mm == "$DEVT" ]] || continue
            S2=1
            mp=$(unesc "$mp")
            act "bind-pinned ns $tgt mounts $DEVT at '$mp'"
            run nsenter --mount="$tgt" -- umount -l "$mp"
        done <<<"$out"
    done < <(findmnt -rno TARGET,FSTYPE 2>/dev/null | awk '$2=="nsfs"{print $1}')
fi
((S2)) || note "none"

# ---------------------------------------------------------------------------
# STEP 3: open references with no mount entry (the lazy-unmount case).
# `umount -l` removed the mount table entry but each open fd still holds
# s_active. Closing them (i.e. killing the owner) is what retires the sb.
# ---------------------------------------------------------------------------
head2 "step 3 - processes holding files on the orphaned filesystem"
S3=0
declare -A KILL=()
decdev() { [[ $1 =~ ^[0-9]+$ ]]; }
hexdev() { [[ $1 =~ ^[0-9a-fA-F]+$ ]]; }
# st_dev == STDEV means "this path lives on the fs mounted from our device".
# Read %R, %d and %r because which of %R/%r is decimal varies by coreutils
# version; accept a match on any plausible reading rather than trusting one.
onfs() {
    local R d r n
    read -r R d r < <(stat -L -c '%R %d %r' "$1" 2>/dev/null) || return 1
    decdev "${d:-}" && (( 10#$d == STDEV )) && return 0
    for n in "${R:-}" "${r:-}"; do
        [[ -n $n ]] || continue
        decdev "$n" && (( 10#$n == STDEV )) && return 0
        hexdev "$n" && (( 16#$n == STDEV )) && return 0
    done
    return 1
}
for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    comm=$(cat "$p/comm" 2>/dev/null) || continue
    why=""
    for l in "$p"/fd/*; do
        [[ -e $l ]] || continue
        onfs "$l" && { why="fd $(basename "$l") -> $(readlink "$l" 2>/dev/null)"; break; }
    done
    if [[ -z $why ]]; then
        for sp in cwd root exe; do
            onfs "$p/$sp" && { why="$sp on this fs"; break; }
        done
    fi
    [[ -n $why ]] || continue
    S3=1
    st=$(awk '{print $3}' "$p/stat" 2>/dev/null)
    act "pid $pid ($comm, state=$st): $why"
    KILL[$pid]="$comm"
done
if ((S3)); then
    if (( APPLY )); then
        act "sending SIGTERM to: ${!KILL[*]}"
        kill -TERM "${!KILL[@]}" 2>/dev/null
        sleep 5
        REMAIN=()
        for pid in "${!KILL[@]}"; do [[ -d /proc/$pid ]] && REMAIN+=("$pid"); done
        if ((${#REMAIN[@]})); then
            act "still alive, sending SIGKILL to: ${REMAIN[*]}"
            kill -KILL "${REMAIN[@]}" 2>/dev/null
            sleep 5
        fi
        # A process wedged in D-state cannot be killed at all: it is blocked
        # inside the kernel waiting on I/O that will never complete. Step 4 is
        # the only thing that unblocks it.
        for pid in "${!KILL[@]}"; do
            [[ -d /proc/$pid ]] || continue
            st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
            note "pid $pid (${KILL[$pid]}) SURVIVED, state=$st"
            [[ $st == D ]] && note "  D-state: unkillable until the I/O it waits on is aborted -> step 4"
        done
    else
        act "WOULD kill: ${!KILL[*]}"
        note "review this list first -- SIGKILL loses unflushed writes in those procs"
    fi
else
    note "none"
fi

# ---------------------------------------------------------------------------
# STEP 4: force the XFS log down.
# Only needed when step 3 found holders stuck in D-state. shutdown aborts all
# in-flight and future I/O with EIO, which is what lets those tasks return from
# the kernel, die, and drop their references. It is exactly what XFS does to
# itself on a fatal error, and is metadata-safe: the log replays on next mount.
# ---------------------------------------------------------------------------
head2 "step 4 - force-shutdown the XFS log (only if step 3 left D-state tasks)"
if [[ $FSTYPE != xfs ]]; then
    note "not xfs ($FSTYPE) - not applicable"
else
    ERRDIR="/sys/fs/xfs/$KNAME/error"
    if [[ -d $ERRDIR ]]; then
        note "error-handling knobs present at $ERRDIR"
        note "if a task is stuck retrying I/O forever, stop the retries:"
        note "  echo 0 > $ERRDIR/fail_at_unmount"
        note "  for d in $ERRDIR/metadata/*/; do echo 0 > \$d/max_retries; echo 0 > \$d/retry_timeout_seconds; done"
        if (( APPLY )); then
            echo 0 > "$ERRDIR/fail_at_unmount" 2>/dev/null && act "fail_at_unmount=0"
            for d in "$ERRDIR"/metadata/*/; do
                [[ -d $d ]] || continue
                echo 0 > "$d/max_retries" 2>/dev/null
                echo 0 > "$d/retry_timeout_seconds" 2>/dev/null
            done
            act "metadata retries disabled - stuck retry loops will now fail fast"
        fi
    else
        note "$ERRDIR absent on this kernel"
    fi
    note ""
    note "to force the shutdown you need any path on the fs; with no mount left,"
    note "reach it through a namespace that still has one:"
    note "  xfs_io -x -c 'shutdown -f' <any-path-on-that-fs>"
    note "  nsenter --mount=<pinned-ns> xfs_io -x -c 'shutdown -f' <mountpoint>"
    note "-f flushes first; drop it to abort immediately. Either way the log"
    note "replays cleanly on the next mount - no data at rest is lost."
fi

# ---------------------------------------------------------------------------
# Verify: the sysfs entry disappearing IS the success condition.
# ---------------------------------------------------------------------------
head2 "result"
if [[ -d /sys/fs/$FSTYPE/$KNAME ]]; then
    printf '  superblock STILL REGISTERED at /sys/fs/%s/%s\n\n' "$FSTYPE" "$KNAME"
    if (( APPLY )); then
        printf '  Something still holds s_active. Re-run ./find-bd-holder.sh, then:\n'
        printf '    * a holder was found but survived   -> step 4 (shutdown), then re-run\n'
        printf '    * D-state tasks remain              -> step 4 is mandatory\n'
        printf '    * genuinely nothing found anywhere  -> the reference is unreachable\n'
        printf '                                           from userspace; reboot is then\n'
        printf '                                           the honest answer\n'
    else
        printf '  Report-only run. Re-run with --apply to act on the above.\n'
    fi
    exit 1
fi

printf '  CLEARED - /sys/fs/%s/%s is gone. The superblock was retired.\n\n' "$FSTYPE" "$KNAME"
printf '  Remount will now succeed on this node. Verify:\n'
printf '    dmsetup info -c --noheadings -o open -j %d -m %d      # expect 0\n' "$MAJ" "$MIN"
printf '    lvs -o lv_name,lv_device_open,lv_attr %s\n' "$(dirname "$DEV")"
printf '    mount %s /mnt/test && umount /mnt/test\n' "$DEV"
printf '\n  If deactivation now fails with a LOCK error rather than EBUSY, that is\n'
printf '  lvmlockd/sanlock, a separate layer:  lvmlockctl -i\n'
