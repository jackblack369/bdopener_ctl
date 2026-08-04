// SPDX-License-Identifier: GPL-2.0
/*
 * bdopener_ctl - inspect and forcibly release leaked block_device open
 *                references (bd_openers) on a live kernel.
 *
 * Motivating case: an LVM LV backing a Kubernetes PVC (nvmeof + sanlock +
 * lvmlockd) shows lv_device_open / dmsetup open == 1 with no mountpoint and
 * no process holding an fd, so lvchange -an and dmsetup remove both fail with
 * EBUSY forever.
 *
 * Scope: this module only drops a phantom open count. It never writes to the
 * LV, wipes signatures, or removes a logical volume - the data is untouched.
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS DOES
 *
 * A leaked reference is an unbalanced blkdev_get(): it incremented both
 *   (a) bdev->bd_openers            - what LVM reports as lv_device_open
 *   (b) the driver's own count      - e.g. dm's md->open_count, which is what
 *                                     actually makes dmsetup remove return
 *                                     EBUSY, and is private to dm-core
 *
 * Poking only (a) leaves you just as busy, now with a corrupt counter. So the
 * "release" command replays a complete blkdev_put(): it decrements bd_openers
 * AND invokes disk->fops->release(), holding the same lock the real put path
 * holds (bd_disk->open_mutex on >= 5.19, bd_mutex before that).
 *
 * Safety invariant: the module opens the device itself before operating, so it
 * always owns one live reference. It refuses unless
 *         bd_openers >= 1 (ours) + requested
 * and therefore can never drive the counter below zero.
 *
 * ---------------------------------------------------------------------------
 * THIS IS STILL A LAST RESORT
 *
 * If a holder genuinely still exists (a live nvmet namespace, an upper dm
 * target, a loop device), forcing the count down does not free anything - it
 * makes the kernel believe the device is idle while a live consumer keeps
 * issuing I/O to it. That path ends in use-after-free and data corruption.
 *
 * Run find-bd-holder.sh first. Then try, in order:
 *      dmsetup remove --deferred <name>
 *      dmsetup remove --force <name>
 * Only use this module when those have failed and no holder can be found.
 *
 * ---------------------------------------------------------------------------
 * USAGE
 *
 *   insmod bdopener_ctl.ko                       # inspect-only, default
 *   insmod bdopener_ctl.ko allow_release=1       # arm the release path
 *
 *   echo 'inspect /dev/csi-lvm/pvc-4ef0ed25-fbda-448a-a9ad-15ee68b4fd3a' \
 *        > /proc/bdopener_ctl
 *   cat /proc/bdopener_ctl                       # last result
 *
 *   # release one leaked reference; dev_t must match what inspect reported
 *   echo 'release /dev/csi-lvm/pvc-4ef0ed25-fbda-448a-a9ad-15ee68b4fd3a 1 253:7 CONFIRM' \
 *        > /proc/bdopener_ctl
 *
 * The explicit dev_t and the literal CONFIRM token are mandatory on release:
 * they make it impossible to hit the wrong device via a stale symlink.
 *
 * Kernel support: 4.18 - 6.12 mainline. Vendor kernels (RHEL, SLES) backport
 * block-layer changes across version boundaries; if it will not build, see
 * the OVERRIDES block below.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/version.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/namei.h>
#include <linux/blkdev.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 18, 0)
#include <linux/genhd.h>	/* folded into blkdev.h in 5.18 */
#endif
#include <linux/proc_fs.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)
#include <linux/stdarg.h>	/* va_list; came from kernel.h before 5.15 */
#endif
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/capability.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Inspect and forcibly release leaked block device bd_openers");
MODULE_VERSION("1.0");

/* ------------------------------------------------------------------ tunables */

static bool allow_release;
module_param(allow_release, bool, 0644);
MODULE_PARM_DESC(allow_release,
	"Permit the destructive 'release' command (default: inspect only)");

static bool skip_driver_release;
module_param(skip_driver_release, bool, 0644);
MODULE_PARM_DESC(skip_driver_release,
	"Decrement bd_openers WITHOUT calling fops->release. Almost never what "
	"you want: leaves dm's open_count high so dmsetup remove still fails.");

static bool force_holder;
module_param(force_holder, bool, 0644);
MODULE_PARM_DESC(force_holder,
	"Override the exclusive-holder veto. bd_holders > 0 means a live "
	"claimant (mounted fs, dm, md, nvmet) owns a reference; releasing it "
	"causes use-after-free. Setting this to 1 is almost always a mistake.");

/* ------------------------------------------------------- version portability */
/*
 * OVERRIDES - pass via ccflags-y in the Makefile if a vendor kernel disagrees
 * with the LINUX_VERSION_CODE heuristics below:
 *
 *   -DBDOC_LOCK_IN_GENDISK=1   bd_disk->open_mutex   (mainline >= 5.19)
 *   -DBDOC_LOCK_IN_GENDISK=0   bdev->bd_mutex        (mainline <  5.19)
 *   -DBDOC_OPENERS_ATOMIC=1    bd_openers is atomic_t
 *   -DBDOC_HANDLE_API=2        bdev_file_open_by_dev  (>= 6.9)
 *   -DBDOC_HANDLE_API=1        bdev_open_by_dev       (>= 6.5)
 *   -DBDOC_HANDLE_API=0        blkdev_get_by_dev      (<  6.5)
 *
 * Verify against your tree:
 *   grep -n 'bd_openers\|open_mutex' /lib/modules/$(uname -r)/build/include/linux/blk_types.h
 */

#ifndef BDOC_LOCK_IN_GENDISK
#  if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 19, 0)
#    define BDOC_LOCK_IN_GENDISK 1
#  else
#    define BDOC_LOCK_IN_GENDISK 0
#  endif
#endif

#ifndef BDOC_HANDLE_API
#  if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 9, 0)
#    define BDOC_HANDLE_API 2
#  elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 5, 0)
#    define BDOC_HANDLE_API 1
#  else
#    define BDOC_HANDLE_API 0
#  endif
#endif

#ifndef BDOC_OPENERS_ATOMIC
#  define BDOC_OPENERS_ATOMIC 0
#endif

#if BDOC_LOCK_IN_GENDISK
#  define BDOC_LOCK(bdev)	(&(bdev)->bd_disk->open_mutex)
#  define BDOC_LOCK_NAME	"bd_disk->open_mutex"
#else
#  define BDOC_LOCK(bdev)	(&(bdev)->bd_mutex)
#  define BDOC_LOCK_NAME	"bdev->bd_mutex"
#endif

#if BDOC_OPENERS_ATOMIC
#  define BDOC_OPENERS_READ(bdev)	atomic_read(&(bdev)->bd_openers)
#  define BDOC_OPENERS_DEC(bdev)	atomic_dec(&(bdev)->bd_openers)
#else
#  define BDOC_OPENERS_READ(bdev)	((long)(bdev)->bd_openers)
#  define BDOC_OPENERS_DEC(bdev)	((bdev)->bd_openers--)
#endif

/*
 * How many bd_holders our own open contributes.
 *
 * On >= 6.5 (bdev_open_by_dev / bdev_file_open_by_dev) a non-NULL holder makes
 * the open EXCLUSIVE, so we take a holder slot ourselves. Before that,
 * exclusivity came from FMODE_EXCL, which we do not pass, so we take none.
 *
 * Note that on >= 6.5 our exclusive open would itself fail with -EBUSY if a
 * filesystem already held the device, so the veto below is belt-and-braces
 * there; on <= 6.4 (incl. the 5.15 vendor kernels this was written for) the
 * veto is the ONLY thing that sees the mounted filesystem.
 */
#if BDOC_HANDLE_API >= 1
#  define BDOC_OUR_HOLDERS 1
#else
#  define BDOC_OUR_HOLDERS 0
#endif

/* Our holder cookie; distinguishes our own open from everyone else's. */
static int bdoc_holder;

/* ------------------------------------------------------- open / close bridge */

struct bdoc_ref {
	struct block_device *bdev;
#if BDOC_HANDLE_API == 2
	struct file *file;
#elif BDOC_HANDLE_API == 1
	struct bdev_handle *handle;
#endif
};

static int bdoc_open(dev_t dev, struct bdoc_ref *ref)
{
	memset(ref, 0, sizeof(*ref));

#if BDOC_HANDLE_API == 2
	ref->file = bdev_file_open_by_dev(dev, BLK_OPEN_READ, &bdoc_holder, NULL);
	if (IS_ERR(ref->file))
		return PTR_ERR(ref->file);
	ref->bdev = file_bdev(ref->file);
#elif BDOC_HANDLE_API == 1
	ref->handle = bdev_open_by_dev(dev, BLK_OPEN_READ, &bdoc_holder, NULL);
	if (IS_ERR(ref->handle))
		return PTR_ERR(ref->handle);
	ref->bdev = ref->handle->bdev;
#else
	ref->bdev = blkdev_get_by_dev(dev, FMODE_READ, &bdoc_holder);
	if (IS_ERR(ref->bdev))
		return PTR_ERR(ref->bdev);
#endif
	return 0;
}

static void bdoc_close(struct bdoc_ref *ref)
{
#if BDOC_HANDLE_API == 2
	fput(ref->file);
#elif BDOC_HANDLE_API == 1
	bdev_release(ref->handle);
#else
	blkdev_put(ref->bdev, FMODE_READ);
#endif
	ref->bdev = NULL;
}

/*
 * Count exclusive claimants other than ourselves.
 *
 * bd_holders is incremented by bd_prepare_to_claim()/bd_link_disk_holder() for
 * every EXCLUSIVE opener: a mounted filesystem's superblock, an upper dm
 * target, md, LIO, nvmet's iblock backend, swapon, losetup. It is therefore a
 * direct answer to the one question bd_openers cannot answer -- is this
 * reference legitimately owned by something still alive?
 *
 * A leaked/orphaned reference has NO holder. A live consumer has one. Those two
 * cases are numerically identical in bd_openers, which is exactly how forcing a
 * release on a still-mounted filesystem became possible.
 *
 * bd_holders has existed since long before 4.18 and is still present in 6.12,
 * so unlike bd_super (deleted in 6.0) it needs no version gate.
 */
static int bdoc_foreign_holders(struct block_device *bdev)
{
	int held = bdev->bd_holders - BDOC_OUR_HOLDERS;

	return held > 0 ? held : 0;
}

/* Invoke the driver's release callback exactly as the real put path does. */
static void bdoc_call_driver_release(struct block_device *bdev)
{
	struct gendisk *disk = bdev->bd_disk;

	if (!disk || !disk->fops || !disk->fops->release)
		return;

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 5, 0)
	disk->fops->release(disk);
#else
	disk->fops->release(disk, FMODE_READ);
#endif
}

/* ------------------------------------------------------------- result buffer */

#define BDOC_OUT_SZ 4096

static DEFINE_MUTEX(bdoc_lock);
static char *bdoc_out;
static size_t bdoc_out_len;

static void bdoc_reset(void)
{
	bdoc_out_len = 0;
	if (bdoc_out)
		bdoc_out[0] = '\0';
}

static __printf(1, 2) void bdoc_emit(const char *fmt, ...)
{
	va_list args;
	int n;

	if (!bdoc_out || bdoc_out_len >= BDOC_OUT_SZ - 1)
		return;

	va_start(args, fmt);
	n = vsnprintf(bdoc_out + bdoc_out_len, BDOC_OUT_SZ - bdoc_out_len, fmt, args);
	va_end(args);

	if (n > 0)
		bdoc_out_len = min_t(size_t, bdoc_out_len + n, BDOC_OUT_SZ - 1);
}

/* ------------------------------------------------------------ path -> dev_t */

static int bdoc_resolve(const char *path, dev_t *dev)
{
	struct path p;
	struct inode *inode;
	int ret;

	ret = kern_path(path, LOOKUP_FOLLOW, &p);
	if (ret)
		return ret;

	inode = d_backing_inode(p.dentry);
	if (!S_ISBLK(inode->i_mode)) {
		path_put(&p);
		return -ENOTBLK;
	}

	*dev = inode->i_rdev;
	path_put(&p);
	return 0;
}

/* ------------------------------------------------------------------ inspect */

static void bdoc_report(struct block_device *bdev, dev_t dev)
{
	struct gendisk *disk = bdev->bd_disk;
	long openers = BDOC_OPENERS_READ(bdev);
	int held = bdoc_foreign_holders(bdev);

	bdoc_emit("dev_t          : %u:%u\n", MAJOR(dev), MINOR(dev));
	bdoc_emit("disk           : %s\n", disk && disk->disk_name[0] ? disk->disk_name : "?");
	bdoc_emit("partno         : %d\n", bdev->bd_partno);
	bdoc_emit("bd_openers     : %ld\n", openers);
	bdoc_emit("  (includes 1 reference held by this module during inspect)\n");
	bdoc_emit("unaccounted    : %ld   (bd_openers minus our own; NOT proof of a leak)\n",
		  openers > 0 ? openers - 1 : 0);
	bdoc_emit("bd_holders     : %d\n", bdev->bd_holders);
	bdoc_emit("foreign holders: %d\n", held);
	if (held > 0) {
		bdoc_emit("verdict        : OWNED, NOT LEAKED -- release will be REFUSED\n");
		bdoc_emit("  A live exclusive claimant holds this device. Look for a\n");
		bdoc_emit("  mounted fs (/sys/fs/*/%s), upper dm, md, loop, swap,\n",
			  disk && disk->disk_name[0] ? disk->disk_name : "<dev>");
		bdoc_emit("  LIO, or an nvmet namespace. Release it at ITS layer.\n");
	} else {
		bdoc_emit("verdict        : no exclusive holder visible\n");
		bdoc_emit("  Consistent with a leak, but NOT conclusive: a holder in a\n");
		bdoc_emit("  hidden mount namespace can still exist. Run\n");
		bdoc_emit("  find-bd-holder.sh and check /sys/fs/*/%s before releasing.\n",
			  disk && disk->disk_name[0] ? disk->disk_name : "<dev>");
	}
	bdoc_emit("read_only      : %d\n", bdev_read_only(bdev) ? 1 : 0);
	bdoc_emit("size (sectors) : %llu\n",
		  (unsigned long long)bdev_nr_sectors(bdev));
	bdoc_emit("lock in use    : %s\n", BDOC_LOCK_NAME);
	bdoc_emit("driver release : %s\n",
		  (disk && disk->fops && disk->fops->release) ? "present" : "absent");
}

static int bdoc_cmd_inspect(const char *path)
{
	struct bdoc_ref ref;
	dev_t dev;
	int ret;

	ret = bdoc_resolve(path, &dev);
	if (ret) {
		bdoc_emit("resolve %s failed: %d\n", path, ret);
		return ret;
	}

	ret = bdoc_open(dev, &ref);
	if (ret) {
		bdoc_emit("open %u:%u failed: %d\n", MAJOR(dev), MINOR(dev), ret);
		return ret;
	}

	bdoc_emit("== inspect %s ==\n", path);
	bdoc_report(ref.bdev, dev);

	bdoc_close(&ref);
	return 0;
}

/* ------------------------------------------------------------------ release */

static int bdoc_cmd_release(const char *path, long count, dev_t expect)
{
	struct bdoc_ref ref;
	dev_t dev;
	long before, after, i;
	int ret, held;

	if (!allow_release) {
		bdoc_emit("refused: module loaded without allow_release=1\n");
		return -EPERM;
	}
	if (count < 1 || count > 64) {
		bdoc_emit("refused: count %ld out of range [1,64]\n", count);
		return -EINVAL;
	}

	ret = bdoc_resolve(path, &dev);
	if (ret) {
		bdoc_emit("resolve %s failed: %d\n", path, ret);
		return ret;
	}
	if (dev != expect) {
		bdoc_emit("refused: %s is %u:%u but you asserted %u:%u\n",
			  path, MAJOR(dev), MINOR(dev),
			  MAJOR(expect), MINOR(expect));
		return -EINVAL;
	}

	ret = bdoc_open(dev, &ref);
	if (ret) {
		bdoc_emit("open %u:%u failed: %d\n", MAJOR(dev), MINOR(dev), ret);
		return ret;
	}

	mutex_lock(BDOC_LOCK(ref.bdev));

	before = BDOC_OPENERS_READ(ref.bdev);

	/*
	 * We hold one reference ourselves, so a legal release of N requires
	 * bd_openers >= N + 1. This is the guard that makes underflow
	 * impossible; do not relax it.
	 */
	if (before < count + 1) {
		bdoc_emit("refused: bd_openers is %ld (ours included); "
			  "releasing %ld would underflow\n", before, count);
		mutex_unlock(BDOC_LOCK(ref.bdev));
		bdoc_close(&ref);
		return -EINVAL;
	}

	/*
	 * The provenance guard. bd_openers arithmetic cannot tell an orphaned
	 * reference from one a live filesystem legitimately owns; bd_holders
	 * can. Refuse when a foreign exclusive claimant exists -- releasing its
	 * reference leaves it submitting I/O to a device the kernel believes is
	 * idle, and leaves a superblock whose next real blkdev_put() underflows
	 * the counter with no guard in the way.
	 */
	held = bdoc_foreign_holders(ref.bdev);
	if (held > 0 && !force_holder) {
		bdoc_emit("REFUSED: %d foreign exclusive holder(s) on this device "
			  "(bd_holders=%d).\n", held, ref.bdev->bd_holders);
		bdoc_emit("This reference is OWNED, not leaked. Releasing it "
			  "risks use-after-free.\n");
		bdoc_emit("Typical holders: a mounted filesystem (check "
			  "/sys/fs/*/%s), an upper dm\n",
			  ref.bdev->bd_disk ? ref.bdev->bd_disk->disk_name : "<dev>");
		bdoc_emit("target, md, losetup, swap, LIO, or an nvmet namespace.\n");
		bdoc_emit("Release it at ITS layer instead: umount (incl. hidden "
			  "namespaces), or\n");
		bdoc_emit("unlink the nvmet ns. If the mount is unreachable, "
			  "reboot the node.\n");
		pr_warn("bdopener_ctl: REFUSED release on %u:%u (%s): %d foreign "
			"exclusive holder(s), reference is owned not leaked\n",
			MAJOR(dev), MINOR(dev), path, held);
		mutex_unlock(BDOC_LOCK(ref.bdev));
		bdoc_close(&ref);
		return -EBUSY;
	}

	for (i = 0; i < count; i++) {
		BDOC_OPENERS_DEC(ref.bdev);
		if (!skip_driver_release)
			bdoc_call_driver_release(ref.bdev);
	}

	after = BDOC_OPENERS_READ(ref.bdev);

	mutex_unlock(BDOC_LOCK(ref.bdev));

	pr_warn("bdopener_ctl: FORCED release of %ld reference(s) on %u:%u (%s), "
		"bd_openers %ld -> %ld%s\n",
		count, MAJOR(dev), MINOR(dev), path, before, after,
		skip_driver_release ? " [fops->release SKIPPED]" : "");

	bdoc_emit("== release %s ==\n", path);
	bdoc_emit("dev_t          : %u:%u\n", MAJOR(dev), MINOR(dev));
	bdoc_emit("released       : %ld\n", count);
	bdoc_emit("bd_openers     : %ld -> %ld (still +1 for our own ref)\n",
		  before, after);
	bdoc_emit("fops->release  : %s\n",
		  skip_driver_release ? "SKIPPED (driver count left stale)" : "called");
	bdoc_emit("expect final   : %ld once this module drops its reference\n",
		  after - 1);
	bdoc_emit("\nnext: dmsetup info -c <name>   # confirm open count dropped\n");
	bdoc_emit("      lvchange -an <vg>/<lv>    # deactivate; LV data untouched\n");

	bdoc_close(&ref);
	return 0;
}

/* --------------------------------------------------------------- proc plumbing */

/* "release <path> <count> <maj:min> CONFIRM" | "inspect <path>" */
static int bdoc_parse_and_run(char *line)
{
	char *verb, *path, *tok;
	long count = 1;
	unsigned int maj, min;
	dev_t expect;

	verb = strsep(&line, " \t");
	if (!verb || !*verb)
		return -EINVAL;

	path = strsep(&line, " \t");
	if (!path || !*path) {
		bdoc_emit("usage: inspect <dev> | release <dev> <count> <maj:min> CONFIRM\n");
		return -EINVAL;
	}

	if (!strcmp(verb, "inspect"))
		return bdoc_cmd_inspect(path);

	if (strcmp(verb, "release")) {
		bdoc_emit("unknown command '%s'\n", verb);
		return -EINVAL;
	}

	tok = strsep(&line, " \t");
	if (!tok || kstrtol(tok, 10, &count)) {
		bdoc_emit("release: bad or missing count\n");
		return -EINVAL;
	}

	tok = strsep(&line, " \t");
	if (!tok || sscanf(tok, "%u:%u", &maj, &min) != 2) {
		bdoc_emit("release: need explicit <maj:min> matching inspect output\n");
		return -EINVAL;
	}
	expect = MKDEV(maj, min);

	tok = strsep(&line, " \t\n");
	if (!tok || strcmp(tok, "CONFIRM")) {
		bdoc_emit("release: missing literal CONFIRM token\n");
		return -EINVAL;
	}

	return bdoc_cmd_release(path, count, expect);
}

static ssize_t bdoc_write(struct file *f, const char __user *ubuf,
			  size_t len, loff_t *off)
{
	char *kbuf;
	int ret;

	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;
	if (len == 0 || len > PATH_MAX + 64)
		return -EINVAL;

	kbuf = memdup_user_nul(ubuf, len);
	if (IS_ERR(kbuf))
		return PTR_ERR(kbuf);

	strim(kbuf);

	mutex_lock(&bdoc_lock);
	bdoc_reset();
	ret = bdoc_parse_and_run(kbuf);
	mutex_unlock(&bdoc_lock);

	kfree(kbuf);

	/* Command outcome is readable via cat; a failed command is still a
	 * successful write so the caller can read the reason. */
	return ret == -EFAULT ? ret : len;
}

static int bdoc_show(struct seq_file *m, void *v)
{
	mutex_lock(&bdoc_lock);
	if (bdoc_out_len)
		seq_puts(m, bdoc_out);
	else
		seq_puts(m,
			 "bdopener_ctl: no command run yet\n"
			 "\n"
			 "  echo 'inspect /dev/vg/lv' > /proc/bdopener_ctl\n"
			 "  echo 'release /dev/vg/lv 1 253:7 CONFIRM' > /proc/bdopener_ctl\n"
			 "\n"
			 "run find-bd-holder.sh first; release is a last resort\n");
	mutex_unlock(&bdoc_lock);
	return 0;
}

static int bdoc_proc_open(struct inode *inode, struct file *f)
{
	return single_open(f, bdoc_show, NULL);
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)
static const struct proc_ops bdoc_proc_ops = {
	.proc_open	= bdoc_proc_open,
	.proc_read	= seq_read,
	.proc_write	= bdoc_write,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};
#else
static const struct file_operations bdoc_proc_ops = {
	.owner		= THIS_MODULE,
	.open		= bdoc_proc_open,
	.read		= seq_read,
	.write		= bdoc_write,
	.llseek		= seq_lseek,
	.release	= single_release,
};
#endif

static int __init bdoc_init(void)
{
	bdoc_out = kzalloc(BDOC_OUT_SZ, GFP_KERNEL);
	if (!bdoc_out)
		return -ENOMEM;

	if (!proc_create("bdopener_ctl", 0600, NULL, &bdoc_proc_ops)) {
		kfree(bdoc_out);
		return -ENOMEM;
	}

	pr_info("bdopener_ctl: loaded (allow_release=%d, lock=%s, handle_api=%d)\n",
		allow_release, BDOC_LOCK_NAME, BDOC_HANDLE_API);
	if (allow_release)
		pr_warn("bdopener_ctl: destructive release path is ARMED\n");

	return 0;
}

static void __exit bdoc_exit(void)
{
	remove_proc_entry("bdopener_ctl", NULL);
	kfree(bdoc_out);
	pr_info("bdopener_ctl: unloaded\n");
}

module_init(bdoc_init);
module_exit(bdoc_exit);
