# Build a bootable SidwaOS disk image with the kernel's own bootloader.
#
#   make          build kernel.elf and disk.img (self-booting, no GRUB)
#   make usb      build usb.img, a 64 MiB image to dd onto a pendrive
#   make iso      build os.iso via GRUB, as an optical-media alternative
#   make run      boot disk.img in QEMU with the serial console on stdio
#   make test     boot headless and assert the expected serial trace
#   make cli      drive the serial command line and check the responses
#   make agent    run the host-side AI agent against the kernel
#   make check    run all three suites
#   make clean    remove build artefacts

CC       := gcc
ASM      := nasm
LD       := ld

CFLAGS   := -m32 -std=gnu11 -O2 -Wall -Wextra \
            -ffreestanding -fno-pic -fno-pie -fno-stack-protector \
            -fno-builtin -nostdlib -Iinclude

ASMFLAGS := -f elf32

LDFLAGS  := -m elf_i386 -T linker.ld -nostdlib

C_SRCS   := $(wildcard boot/*.c cpu/*.c kernel/*.c drivers/*.c)
# stage1/stage2 are raw boot sectors assembled by tools/mkboot.py, not kernel
# objects, so they stay out of the link.
ASM_SRCS := $(filter-out boot/stage1.asm boot/stage2.asm, \
             $(wildcard boot/*.asm cpu/*.asm kernel/*.asm drivers/*.asm))
OBJS     := $(C_SRCS:.c=.o) $(ASM_SRCS:.asm=.o)

KERNEL   := kernel.elf
ISO      := os.iso
DISK     := disk.img
USB      := usb.img

.PHONY: all run test cli agent check pdf usb iso clean web zip

# The default build is a self-booting disk image: stage 1 and stage 2 read the
# kernel straight off the disk. No GRUB is involved.
all: $(DISK)

$(KERNEL): $(OBJS) linker.ld
	$(LD) $(LDFLAGS) -o $@ $(OBJS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.asm
	$(ASM) $(ASMFLAGS) $< -o $@

$(DISK): $(KERNEL) boot/stage1.asm boot/stage2.asm tools/mkboot.py tools/mkapp.py
	python3 tools/mkboot.py $(DISK) --size-mb 8

usb: $(KERNEL) boot/stage1.asm boot/stage2.asm tools/mkboot.py tools/mkapp.py
	python3 tools/mkboot.py $(USB) --size-mb 64

# The GRUB ISO is kept as an alternative for machines that boot optical media.
iso: $(KERNEL) iso/boot/grub/grub.cfg
	cp $(KERNEL) iso/boot/$(KERNEL)
	grub-mkrescue -o $(ISO) iso

run: $(DISK)
	qemu-system-i386 -drive file=$(DISK),format=raw,if=ide \
	    -netdev user,id=n0 -device rtl8139,netdev=n0 \
	    -serial stdio -display none -no-reboot -no-shutdown

test: $(DISK)
	python3 tools/test_persistence.py
	bash tools/test.sh

cli: $(DISK)
	python3 tools/cli_test.py

agent: $(DISK)
	python3 tools/agent.py --check

check: test cli agent

.PHONY: test-persistence
test-persistence:
	python3 tools/test_persistence.py

# Serve the web interface: the page, the chat and the disk download, on port 80
# and the public work-host ports. One QEMU instance backs them all.
web: $(DISK)
	SIDWAOS_WEB_PORTS=$${SIDWAOS_WEB_PORTS:-80,12000,12001} python3 web/server.py

# Package the system: every source file, plus the built disk.img so it can be
# run without building. Regenerates docs first so the zip is never stale.
zip: $(DISK) pdf
	python3 tools/mkzip.py

pdf:
	python3 tools/mkpdf.py

clean:
	rm -f $(OBJS) $(KERNEL) $(ISO) $(DISK) $(USB) serial.log
	rm -f docs/sidwaos-cli.pdf
