obj-m += bdopener_ctl.o

KVER    ?= $(shell uname -r)
KDIR    ?= /lib/modules/$(KVER)/build

# Uncomment / adjust if a vendor kernel disagrees with the version heuristics.
# See the OVERRIDES comment block in bdopener_ctl.c.
ccflags-y += -DBDOC_LOCK_IN_GENDISK=1
# ccflags-y += -DBDOC_HANDLE_API=0
# ccflags-y += -DBDOC_OPENERS_ATOMIC=1

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

# Report which portability branches were selected for this kernel.
probe:
	@echo "kernel : $(KVER)"
	@echo "kdir   : $(KDIR)"
	@test -d $(KDIR) || { echo "MISSING: install kernel-devel/linux-headers-$(KVER)"; exit 1; }
	@grep -n 'bd_openers' $(KDIR)/include/linux/blk_types.h 2>/dev/null \
		|| echo "bd_openers not in blk_types.h - check blkdev.h"
	@grep -n 'open_mutex' $(KDIR)/include/linux/blkdev.h \
		$(KDIR)/include/linux/blk_types.h 2>/dev/null \
		|| echo "no open_mutex - pre-5.19 layout, uses bd_mutex"

.PHONY: all clean load load-armed unload probe
