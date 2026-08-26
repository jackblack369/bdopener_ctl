obj-m += bdopener_ctl.o

KVER    ?= $(shell uname -r)
KDIR    ?= /lib/modules/$(KVER)/build

# --------------------------------------------------------- feature detection
# One tree has to build on 5.15 and 6.8 alike, and the struct members we touch
# did not move at the same release -- nor do distro kernels backport them in
# order. A hardcoded -D here is therefore wrong on the other node by
# construction: -DBDOC_OPENERS_ATOMIC=1 fixes 6.8 and breaks 5.15.
#
# So ask the headers we are about to compile against, not uname:
#
#   bd_openers   int -> atomic_t             5.15 int, 6.8 atomic_t
#   bd_mutex     -> gendisk->open_mutex      5.15 already has open_mutex
#   open API     blkdev_get_by_dev -> bdev_open_by_dev -> bdev_file_open_by_dev
#
# struct gendisk lived in genhd.h until 5.18 folded it into blkdev.h, so both
# get grepped. If a header is unreadable no -D is emitted and the
# LINUX_VERSION_CODE fallback in bdopener_ctl.c decides instead.
BLK_TYPES_H := $(wildcard $(KDIR)/include/linux/blk_types.h)
BLKDEV_H    := $(wildcard $(KDIR)/include/linux/blkdev.h)
GENDISK_H   := $(wildcard $(KDIR)/include/linux/blkdev.h $(KDIR)/include/linux/genhd.h)

ifneq ($(BLK_TYPES_H),)
ccflags-y += -DBDOC_OPENERS_ATOMIC=$(shell \
	grep -qE 'atomic_t[[:space:]]+bd_openers' $(BLK_TYPES_H) && echo 1 || echo 0)
endif

ifneq ($(GENDISK_H),)
ccflags-y += -DBDOC_LOCK_IN_GENDISK=$(shell \
	grep -qE 'struct mutex[[:space:]]+open_mutex' $(GENDISK_H) && echo 1 || echo 0)
endif

ifneq ($(BLKDEV_H),)
ccflags-y += -DBDOC_HANDLE_API=$(shell \
	if   grep -qE '\<bdev_file_open_by_dev\>' $(BLKDEV_H); then echo 2; \
	elif grep -qE '\<bdev_open_by_dev\>'      $(BLKDEV_H); then echo 1; \
	else echo 0; fi)
endif

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

# Load inspect-only. Safe.
load:
	insmod ./bdopener_ctl.ko

# Load with the destructive path armed.
load-armed:
	insmod ./bdopener_ctl.ko allow_release=1

unload:
	rmmod bdopener_ctl

# Report which portability branches were detected for this kernel. Run this
# first on any new node; if a line says "(fallback)" the header grep came up
# empty and bdopener_ctl.c is guessing from LINUX_VERSION_CODE.
probe:
	@echo "kernel  : $(KVER)"
	@echo "kdir    : $(KDIR)"
	@test -d $(KDIR) || { echo "MISSING: install linux-headers-$(KVER)"; exit 1; }
	@echo "detected: $(if $(strip $(ccflags-y)),$(ccflags-y),none - all fallback)"
	@echo "--- evidence ---"
	@grep -nE '(int|atomic_t)[[:space:]]+bd_openers' $(BLK_TYPES_H) \
		|| echo "bd_openers: NOT FOUND (fallback)"
	@grep -nE 'struct mutex[[:space:]]+open_mutex' $(GENDISK_H) \
		|| echo "open_mutex: NOT FOUND -> pre-5.15 bd_mutex layout"
	@grep -nE '\<(blkdev_get_by_dev|bdev_open_by_dev|bdev_file_open_by_dev)\>' $(BLKDEV_H) \
		| head -3 || echo "open API: NOT FOUND (fallback)"

.PHONY: all clean load load-armed unload probe
