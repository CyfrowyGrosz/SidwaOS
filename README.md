# SidwaOS

A minimal bootable x86 operating system kernel written in NASM and C, built
around a **3-state I/O machine** and booting from its own two-stage bootloader
(no GRUB). It runs in QEMU.

## The 3-state I/O machine

Three cooperative loops move data through one machine:

- **State 1 — RUN.** Fragments run on the CPU on a randomised stack base with a
  canary, so a fragment that overruns is caught and dropped instead of taking
  the kernel down. Loop 1, *bit flow*, combines two 4-bit processes into one
  byte.
- **State 2 — HOLD.** Queued data is parked and validated by logic tests and a
  checksum before it is allowed any further.
- **State 3 — STORE.** Programs that passed validation are written to the
  `.sidwa` partition.

## Install and run

Quick version: unpack the zip and boot the `disk.img` it contains, no build
needed.

```sh
qemu-system-i386 -drive file=disk.img,format=raw,if=ide \
    -netdev user,id=n0 -device rtl8139,netdev=n0 -serial stdio -display none
```

See `INSTALL.md` for dependencies, building from source, writing to a pendrive
or a real partition, and connecting a language model.

## Build and run

```sh
make            # build the kernel and disk.img
make run        # boot disk.img in QEMU
make test       # boot and check the serial log
make cli        # drive the command line and check the output
make pdf        # rebuild the command-line manual
make web        # serve the browser console and assistant
make zip        # package sources + bootable disk.img as a zip
```

Requirements: `nasm`, `gcc` (32-bit), `ld`, `qemu-system-i386`.

## Bootloader

The disk is self-booting. `boot/stage1.asm` is the MBR (entry at offset 0) and
reads `boot/stage2.asm` to `0x8000`; stage 2 enters 32-bit protected mode,
parses the kernel ELF and jumps to it with a Multiboot hand-off. `tools/mkboot.py`
lays out the image and patches the kernel LBA, sector count and region base, so
the same kernel works on a whole disk (base 0) or inside a partition
(base = partition start).

## Installer

`tools/install.py` is an install wizard that can take the whole disk, use free
space, or shrink an existing partition. `tools/parttool.py` is a self-contained
MBR/GPT partition tool used by the wizard.

## Command line

At the `os>` prompt, `help` lists every command. The optimisation course
(`optim`) teaches the whole loop — decompile a slow program, rewrite it fast —
and proves it on the machine's own VGA console: `optim bench` times a slow and a
fast frame writer with the cycle counter and checks both draw the same picture.

See `docs/sidwaos-cli.pdf` for the full command-line technical description.

## Documentation

- `AGENTS.md` — conventions and notes for working on the code.
- `docs/sidwaos-cli.pdf` — generated from the `help` text in `kernel/actions.c`.

## Knowledge persistence fix (0.4.0-persistence1)

Rebuilding the boot image previously recreated the entire `disk.img` from zero.
That erased the `.sidwa` knowledge partition at LBA 256 even when the running
system had successfully stored verified facts. `tools/mkboot.py` now preserves
the existing `.sidwa` sectors when rebuilding an existing image, while still
replacing the bootloader, demo blobs and kernel. A fresh image is formatted on
first boot as before.

Run the host-side regression tests with:

```sh
make test-persistence
```

The kernel's fetch flow still deliberately requires two agreeing sources before
persisting a fetched fact (`fetch verify <url-a> | <url-b> | <question>`). A
single page is held as unverified and is not written to durable knowledge.
This release does not add unattended background web crawling: URLs remain an
explicit input so the OS does not silently trust arbitrary pages.
