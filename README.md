# bdopener_ctl

Inspect and forcibly release **leaked `bd_openers` references** on a live block
device — so a stuck LV becomes deactivatable again **without destroying it**.

> ### Scope: this tool never touches LV data
>
> The goal is to drop a *phantom open count*, nothing else.
>
> | | |
> |---|---|
> | **Does** | read `bd_openers`, decrement it, replay `fops->release()` |
> | **Does not** | write to the LV, wipe signatures, `lvremove`, `lvreduce`, `mkfs`, or `dd` |
>
> No command in this README removes a logical volume. After a successful
> release the LV is still fully intact — you simply get a working
> `lvchange -an` / `dmsetup remove` (mapping teardown only) instead of `EBUSY`.

Built for: an LVM LV backing a Kubernetes PVC (nvmeof + sanlock + lvmlockd +
wdmd) that reports open count 1 with **no *visible* mountpoint or process**, so
`lvchange -an` and `dmsetup remove` fail with `EBUSY` indefinitely.

"No visible mountpoint" is frequently a false negative — the fs can be mounted
in an fd-pinned mount namespace that no live process exposes. Read
[Before you build](#before-you-build) before concluding the reference is truly
leaked.

| File | Role |
|------|------|
| `find-bd-holder.sh` | read-only diagnostic — **run this first** |
| `bdopener_ctl.c` | kernel module: inspect + forced release |
| `Makefile` | build / load / probe |

---

## The whole flow at a glance

```mermaid
flowchart TD
    START(["open count > 0<br/>lvchange -an → EBUSY"]) --> DIAG

    subgraph DIAG["① Diagnose — read-only, zero risk"]
        D1["./find-bd-holder.sh /dev/vg/lv"] --> D2{"holder<br/>identified?"}
        D2 -- no --> D3["hunt hidden holders:<br/>lsns · crictl · findmnt · dmesg"]
        D3 --> D4{"fs still mounted<br/>in a hidden ns?"}
    end

    D2 -- yes --> FIX["② Release at the holder's own layer<br/>delete pod · umount staging<br/>unlink nvmet ns · remove upper dm"]
    D4 -- yes --> FIX
    D4 -- no --> WAIT["③ udevadm settle<br/>(udev may still be working)"]

    FIX --> OK
    WAIT --> W2{"count dropped?"}
    W2 -- yes --> OK
    W2 -- no --> DM["④ dmsetup remove --deferred<br/>then --force"]

    DM --> DM2{"count dropped?"}
    DM2 -- yes --> OK
    DM2 -- no --> MOD["⑤ bdopener_ctl release<br/>LAST RESORT"]

    MOD --> M2{"count dropped?"}
    M2 -- yes --> OK
    M2 -- no --> BOOT["⑥ drain + reboot node"]
    BOOT --> OK

    OK(["open count = 0<br/>LV data intact"])

    style START fill:#fde2e2,stroke:#c0392b
    style OK fill:#d5f5e3,stroke:#1e8449
    style MOD fill:#fdebd0,stroke:#b9770e
    style DIAG fill:#eaf2f8,stroke:#2874a6
```

Every step is strictly safer than the one below it. **Do not skip steps** — the
module at ⑤ is the only one that can corrupt kernel state.

---

## Before you build

Your symptom — **open count 1, no visible mountpoint or process** — is the
signature of *some* live kernel-side reference, but that reference is **not
always in kernel context**. Decide which case you are in before arming
anything:

```mermaid
flowchart TD
    Q(["open count 1<br/>nothing visible"]) --> A{"lvchange -an says<br/>'contains a filesystem in use'<br/>(exit 5)?"}

    A -- yes --> FS["<b>Live superblock</b><br/>fs mounted in an fd-pinned<br/>mount namespace"]
    A -- no --> B{"configfs nvmet ns<br/>points at this LV?"}

    B -- yes --> NV["<b>Live nvmet iblock backend</b><br/>blkdev_get_by_path() in kernel —<br/>no fd, no mountpoint"]
    B -- no --> C{"upper dm target ·<br/>losetup · md · LIO · swap?"}

    C -- yes --> UP["<b>Live stacked consumer</b>"]
    C -- no --> LEAK["<b>Plausibly a real counter leak</b><br/>→ module is in scope"]

    FS --> HARM
    NV --> HARM
    UP --> HARM
    HARM["🛑 <b>DO NOT force the count down</b><br/>a live consumer keeps submitting I/O →<br/>use-after-free, then silent corruption"]

    style HARM fill:#fadbd8,stroke:#c0392b,stroke-width:2px
    style LEAK fill:#d5f5e3,stroke:#1e8449
```

### Case A — hidden mount namespace (most common on a k8s node)

An fd-pinned namespace (a leaked `containerd-shim`/kubelet reference, or a pod
whose teardown is still in progress) keeps the mount alive, so **no
`/proc/<pid>/mountinfo` mentions it**. `lvchange -an` then fails with
`Logical volume ... contains a filesystem in use` (exit status 5) — that is a
live superblock, not a counter leak.

This is the case `find-bd-holder.sh`'s own verdict text describes: *"if the
opener has since exited, no visible process."* In practice the opener usually
**hasn't** exited — it's in a hidden namespace.

Prove whether the filesystem really is unmounted:

```bash
lsns -t mnt                                   # NPROCS=0 with a holder PID = fd-pinned
crictl ps -a | grep <pod-uid>                 # container still holding the volume?
findmnt -rn | grep -iE '<lv-name>|253:11'     # incl. CSI staging mounts
dmesg | grep -E 'XFS.*(Mounting|Unmounting)'
# "Mounting V5 Filesystem" + "Ending clean mount" with NO following
# "Unmounting Filesystem" = the fs is still mounted somewhere.
```

### Case B — `nvmet` kernel-context holder

If the fs truly is gone, the classic kernel-context holder is **`nvmet`**: the
NVMe target's `iblock` backend calls `blkdev_get_by_path()` in the kernel, so
there is no fd for `lsof`/`fuser` to report and no mountpoint to unmount. If a
`configfs` namespace still points at that LV — commonly one left with
`enable=0` but never `rmdir`'d, or one whose PVC was deleted out from under it
— the reference is **real, correct, and permanent** until you unlink it:

```bash
grep -r . /sys/kernel/config/nvmet/subsystems/*/namespaces/*/device_path
# find the namespace pointing at your LV, then:
echo 0 > /sys/kernel/config/nvmet/subsystems/<subsys>/namespaces/<nsid>/enable
rmdir   /sys/kernel/config/nvmet/subsystems/<subsys>/namespaces/<nsid>
```

Unlinking the namespace does not modify the LV's contents.

### What the diagnostic covers — and its two blind spots

`find-bd-holder.sh` checks all of the above: a `rdev`/`st_dev`-matched scan of
every `/proc/*/{fd,maps,cwd,root,exe}`, a per-process `mountinfo` scan, and an
fd-pinned-namespace probe. Two limits before trusting an "all clean":

- the fd-pinned probe shells out to `nsenter` and is **silently blind if
  `nsenter` is not installed**;
- the fd/`st_dev` scan reads device numbers via `stat -c '%R %d'` (falling back
  to `%t %T`); on hosts whose `stat` cannot emit those, it reports paths as
  **skipped** rather than matched.

---

## Escalation order

| # | Action | Risk | Touches LV data? |
|---|--------|------|------------------|
| 1 | `./find-bd-holder.sh /dev/csi-lvm/pvc-...` | none, read-only | no |
| 2 | Hunt hidden holders step 1 can miss: `lsns`, `crictl ps -a`, `findmnt -A`, CSI staging paths, the dmesg unmount check | none, read-only | no |
| 3 | Release the holder at its own layer: delete the pod/container, umount the staging mount, unlink the nvmet namespace | normal operation | no |
| 4 | `udevadm settle` — udev may simply still be working | none | no |
| 5 | `dmsetup remove --deferred <name>` — tears down the *mapping* once the count drops | low | no |
| 6 | `dmsetup remove --force <name>` — swaps in an error target, then removes the mapping | moderate; in-flight I/O gets `EIO` | no |
| 7 | **this module's `release`** | high; corrupts kernel state if a holder exists | no |
| 8 | Drain + reboot the node | disruptive but always correct | no |

Steps 5 and 6 are the kernel's own supported answers to exactly this problem
and resolve most real leaks. `dmsetup remove` only removes the device-mapper
mapping — the LV's extents and filesystem stay on disk and reappear on the next
`lvchange -ay`.

**Reach step 7 only when 5 and 6 have failed *and* steps 1–2 found nothing.**

---

## Build

```bash
# RHEL/CentOS/Rocky
sudo dnf install -y kernel-devel-$(uname -r) gcc make
# Debian/Ubuntu
sudo apt install -y linux-headers-$(uname -r) build-essential

make probe    # confirm headers exist and show which struct layout was detected
make
```

`make probe` prints where `bd_openers` and `open_mutex` live in your tree. If
the build fails, the version heuristics guessed wrong for your vendor kernel —
set the `-DBDOC_*` overrides in the `Makefile` per the `OVERRIDES` block in the
`.c`.

Building requires headers on the node and, if Secure Boot is on, a signed
module. On an immutable/CoreOS-style host you will need a `kmod-via-container`
build or a pre-built signed `.ko`.

---

## Use

```mermaid
sequenceDiagram
    autonumber
    participant You
    participant Sh as find-bd-holder.sh
    participant Mod as bdopener_ctl.ko
    participant K as kernel bdev

    You->>Sh: ./find-bd-holder.sh /dev/vg/lv
    Sh-->>You: holders found / none + dm open count

    Note over You,Mod: inspect — safe, default, no params
    You->>Mod: insmod bdopener_ctl.ko
    You->>Mod: echo 'inspect <dev>' > /proc/bdopener_ctl
    Mod->>K: open device (takes 1 ref of its own)
    Mod->>K: read bd_openers
    Mod-->>You: cat /proc/bdopener_ctl → bd_openers, leaked (est.), dev_t

    Note over You,Mod: release — destructive to kernel state, not to data
    You->>Mod: rmmod && insmod allow_release=1
    You->>Mod: echo 'release <dev> <count> <maj:min> CONFIRM'
    Mod->>K: verify bd_openers >= count + 1
    Mod->>K: bd_openers-- , then fops->release()
    Mod-->>You: before → after, pr_warn to dmesg

    You->>Mod: rmmod bdopener_ctl
    You->>K: dmsetup info -c <name>   # confirm open count = 0
```

### Inspect (safe — this is the default)

```bash
chmod +x find-bd-holder.sh
sudo ./find-bd-holder.sh /dev/csi-lvm/pvc-4ef0ed25-fbda-448a-a9ad-15ee68b4fd3a

sudo insmod ./bdopener_ctl.ko
echo 'inspect /dev/csi-lvm/pvc-4ef0ed25-fbda-448a-a9ad-15ee68b4fd3a' \
  | sudo tee /proc/bdopener_ctl
sudo cat /proc/bdopener_ctl
```

```text
== inspect /dev/csi-lvm/pvc-4ef0ed25-fbda-448a-a9ad-15ee68b4fd3a ==
dev_t          : 253:11
disk           : dm-11
bd_openers     : 2
  (includes 1 reference held by this module during inspect)
leaked (est.)  : 1
lock in use    : bd_disk->open_mutex
driver release : present
```

Note `leaked (est.) : 1` — the module holds one reference of its own while
looking, so `bd_openers` reads one higher than what LVM reports.

### Release (destructive to kernel state — LV data untouched)

```bash
sudo rmmod bdopener_ctl
sudo insmod ./bdopener_ctl.ko allow_release=1

# count and dev_t must both match what inspect reported
echo 'release /dev/csi-lvm/pvc-4ef0ed25-fbda-448a-a9ad-15ee68b4fd3a 1 253:11 CONFIRM' \
  | sudo tee /proc/bdopener_ctl
sudo cat /proc/bdopener_ctl

sudo rmmod bdopener_ctl
```

Then **verify only** — no removal, no wipe:

```bash
sudo dmsetup info -c csi--lvm-pvc--4ef0ed25--fbda--448a--a9ad--15ee68b4fd3a
sudo lvs -o lv_name,lv_device_open,lv_attr csi-lvm

# the LV is now deactivatable again; data stays on disk either way
sudo lvchange -an /dev/csi-lvm/pvc-4ef0ed25-fbda-448a-a9ad-15ee68b4fd3a
sudo lvchange -ay /dev/csi-lvm/pvc-4ef0ed25-fbda-448a-a9ad-15ee68b4fd3a   # bring it back
```

The explicit `253:11` and the literal `CONFIRM` are mandatory: a stale symlink
under `/dev/csi-lvm/` after a `dmsetup` reshuffle can point somewhere entirely
different, and asserting the `dev_t` you actually inspected makes hitting the
wrong device impossible. Every release is logged at `pr_warn` to `dmesg`.

---

## Why it decrements *and* calls `fops->release`

For a dm device a single leaked `blkdev_get()` inflated **two** counters:

```mermaid
flowchart LR
    LEAK(["leaked blkdev_get()<br/>unbalanced — no matching put"])

    LEAK --> C1["<b>bdev->bd_openers</b><br/>generic block layer<br/><i>read by lvs -o lv_device_open</i>"]
    LEAK --> C2["<b>md->open_count</b><br/>dm-core private<br/><i>read by dmsetup info -c</i><br/>← this is what returns EBUSY</i>"]

    C1 --> P1["release: bd_openers--"]
    C2 --> P2["release: disk->fops->release()"]

    P1 --> DONE(["both counters consistent<br/>device genuinely idle"])
    P2 --> DONE

    SKIP["skip_driver_release=1<br/>does only this half →<br/>still EBUSY, now with<br/>counters that disagree"] -.-> P1

    style LEAK fill:#fadbd8,stroke:#c0392b
    style DONE fill:#d5f5e3,stroke:#1e8449
    style SKIP fill:#fdebd0,stroke:#b9770e
```

Decrementing only `bd_openers` leaves you just as busy, now with a counter that
disagrees with reality. So `release` replays a **complete `blkdev_put()`**:
decrement, then invoke `disk->fops->release()`, under the same lock the real
put path holds (`bd_disk->open_mutex` on ≥ 5.19, `bdev->bd_mutex` before).

`skip_driver_release=1` exists to decrement only. It is almost never what you
want, and is there for the case where you have already confirmed via
`dmsetup info` that `open_count` is 0 while `bd_openers` is not.

### The two guards, and what each one catches

`release` refuses on two independent grounds. They answer different questions,
and **the arithmetic one is not the important one**.

```mermaid
flowchart TD
    REQ(["release &lt;dev&gt; &lt;count&gt; &lt;maj:min&gt; CONFIRM"]) --> G0{"allow_release=1 ·<br/>dev_t matches ·<br/>count in [1,64]?"}
    G0 -- no --> R0["refuse<br/>-EPERM / -EINVAL"]

    G0 -- yes --> G1{"<b>bd_openers >= count + 1</b><br/>arithmetic:<br/>would it underflow?"}
    G1 -- no --> R1["refuse, -EINVAL"]

    G1 -- yes --> G2{"<b>bd_holders - ours > 0</b><br/>provenance:<br/>is it OWNED?"}
    G2 -- "yes → owned" --> R2["<b>REFUSE, -EBUSY</b><br/>a live claimant holds it<br/><i>this is the guard that<br/>matters</i>"]
    G2 -- "no → unowned" --> GO["proceed:<br/>bd_openers-- + fops->release()"]

    style R2 fill:#fadbd8,stroke:#c0392b,stroke-width:2px
    style GO fill:#d5f5e3,stroke:#1e8449
    style R0 fill:#f4f6f6,stroke:#7f8c8d
    style R1 fill:#f4f6f6,stroke:#7f8c8d
```

**Why arithmetic alone is not enough.** The two cases are numerically identical:

| | `bd_openers` | `bd_holders` | safe? |
|---|---|---|---|
| genuine leak | 2 (ours + orphan) | 0 | yes |
| live superblock | 2 (ours + XFS) | 1 | **no — this is the corruption case** |

`bd_openers >= count + 1` passes in *both*. Only `bd_holders` distinguishes
them: it is incremented by `bd_prepare_to_claim()` for every **exclusive**
claimant — a mounted filesystem's superblock, an upper dm target, md, LIO,
`nvmet`'s iblock backend, `swapon`, `losetup`. An orphaned reference has no
holder; a live consumer does.

`force_holder=1` overrides the provenance veto. It is almost always a mistake;
it exists only so a genuine leak that somehow registers a stale holder is still
recoverable.

### Underflow is structurally impossible

```mermaid
flowchart LR
    A["module opens the device<br/>→ owns 1 live ref"] --> B{"bd_openers >=<br/>count + 1 ?"}
    B -- no --> R["refuse, -EINVAL"]
    B -- yes --> D["proceed"]
    style R fill:#fadbd8,stroke:#c0392b
    style D fill:#d5f5e3,stroke:#1e8449
```

The module opens the device itself before touching anything, so it always owns
one live reference, and refuses unless `bd_openers >= count + 1`. **Do not
relax that check** — it is the only thing standing between a typo and a
negative refcount.

---

## Recovering from a release that should have been refused

If you released a reference that a live filesystem owned, the LV **deactivates
successfully** — and then the next mount fails:

```text
mount: .../mount: fsconfig() failed: File exists.
```

with this in `dmesg`:

```text
sysfs: cannot create duplicate filename '/fs/xfs/dm-5'
  xfs_fs_get_tree → xfs_fs_fill_super → xfs_mountfs → [kobject_add] → -EEXIST
```

### What happened

```mermaid
flowchart TD
    S1["fs live in an fd-pinned mount namespace<br/>bd_openers = 1 — legitimately owned by the superblock"]
    S1 --> S2["release forces the counter to 0<br/>the superblock is untouched — the module cannot destroy one"]
    S2 --> S3["lvchange -an now 'succeeds'<br/>the counter looks idle, so nothing objects"]
    S3 --> S4["<b>zombie superblock</b><br/>still registered at /sys/fs/xfs/dm-5<br/>no mount, no fd, no way to reach it"]
    S4 --> S5["next mount: xfs_mountfs → kobject_add → -EEXIST<br/>surfaced as 'fsconfig() failed: File exists'"]

    style S1 fill:#eaf2f8,stroke:#2874a6
    style S4 fill:#fadbd8,stroke:#c0392b,stroke-width:2px
    style S5 fill:#fdebd0,stroke:#b9770e
```

The `EBUSY` you were trying to defeat was **correct** — it was the kernel
accurately reporting a mounted filesystem. There was never a release-then-mount
path here; the right outcome was for the release to refuse.

Note the error message names the pod's mount directory, but that path is
irrelevant: `fsconfig(FSCONFIG_CMD_CREATE)` builds the **superblock** and hasn't
looked at the destination yet. Recreating or deleting that directory does
nothing.

### Fixing it

```bash
# confirm the zombie
ls -la /sys/fs/xfs/          # an entry for a device with no mount = zombie
findmnt -A -S /dev/<vg>/<lv> # reachable anywhere?
```

- **If a mount is reachable** — `umount` it properly. That retires the
  superblock cleanly and no reboot is needed.
- **If it is not reachable** — **drain and reboot the node.** A superblock with
  no reachable mount cannot be destroyed from userspace: there is no umount
  target, no fd, and no interface to unregister that kobject. This is the
  correct fix, not a fallback.

Two things to avoid while in this state:

- **Stop the kubelet retry loop** (cordon, or scale the workload down). Every
  backoff retry runs `xfs_mountfs` against a device whose refcounts are already
  inconsistent. Deleting the pod does not help — it reschedules and retries.
- **Do not run `release` again,** and do not `lvchange -ay` anything that might
  land on the same dm minor. The forced decrement already consumed a reference
  the zombie superblock still owns; when that fs is eventually put for real,
  `blkdev_put()` decrements again — and the real put path has none of this
  module's guards.

**The LV's data is intact throughout.** It mounts normally after a reboot.

> Since the `bd_holders` veto was added, `release` refuses this case outright,
> so reaching this state now requires `force_holder=1`.

---

## Caveats

- Uses no exported symbol, but does write a `struct block_device` field
  directly. That is not a stable ABI: **re-verify `make probe` after every
  kernel upgrade.**
- Taints the kernel. Vendor support for that node may be void while loaded.
  Unload as soon as you are done.
- `sanlock`/`lvmlockd` hold the VG's internal `lvmlock` LV open, not your
  per-PVC LVs. A stuck lease shows up in `sanlock client status` /
  `lvmlockctl -i`, **not** as elevated `bd_openers` on a PVC. If deactivation
  fails with a lock error rather than `EBUSY`, this module is the wrong tool —
  look at `lvmlockctl --drop <vgname>`.
- Test on a scratch VG on a non-production node first:
  ```bash
  vgcreate testvg /dev/loop0 && lvcreate -n t -L 32M testvg
  # hold it open from kernel context, then inspect
  ```
- If leaks keep recurring, the module is a bandaid. The real bug is upstream —
  usually a CSI driver whose NodeUnpublish/NodeUnstage tears down the mount but
  leaves the filesystem referenced (a leaked container mount namespace, an
  unremoved staging mount, or an `nvmet` namespace it failed to unlink).
  Capture `find-bd-holder.sh` output plus `dmesg` at leak time and file it
  against the driver.
</content>
</invoke>
