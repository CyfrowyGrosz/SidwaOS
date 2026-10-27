# Installing and running SidwaOS

SidwaOS is a minimal bootable x86 kernel with its own two-stage bootloader.
There is no installer ISO to burn and no GRUB dependency: the disk image boots
itself. This guide covers the three ways to run it, from quickest to most
involved.

Everything below was run against the 0.4.0 package.

## 1. Run the prebuilt image (no build, about a minute)

Download the zip, unpack it, and boot the `disk.img` it contains.

```sh
unzip sidwaos-0.4.0.zip
cd sidwaos
qemu-system-i386 -drive file=disk.img,format=raw,if=ide \
    -netdev user,id=n0 -device rtl8139,netdev=n0 \
    -serial stdio -display none -no-reboot
```

You should see the boot banner end with a prompt:

```
3-state I/O machine - type 'help' for commands
os>
```

Type `help` for the command list, `sysinfo` for the machine summary, and `halt`
to stop. This is the whole system: the zip carries the sources *and* the built
image, so nothing has to be compiled to try it.

`make run` does the same QEMU command if you would rather not type it.

## 2. Build from source

### Dependencies

| Need | Why | Debian/Ubuntu package |
|---|---|---|
| `nasm` | assembles the bootloader and kernel stubs | `nasm` |
| `gcc` with 32-bit output | compiles the kernel | `gcc`, plus `gcc-multilib` and `libc6-dev-i386` for `-m32` |
| `ld` | links the kernel ELF | `binutils` |
| `qemu-system-i386` | runs the image | `qemu-system-x86` |
| `python3` | the build and packaging tools | `python3` |

On Debian or Ubuntu:

```sh
sudo apt-get install nasm gcc gcc-multilib libc6-dev-i386 binutils qemu-system-x86 python3
```

The 32-bit support is the step people miss. Check it before building:

```sh
echo 'int main(void){return 0;}' > /tmp/t.c && gcc -m32 -c /tmp/t.c -o /tmp/t.o && echo "32-bit OK"
```

If that fails, `gcc-multilib` is missing. The kernel is freestanding (`-ffreestanding
-nostdlib`), so no 32-bit libc is linked, but the compiler still needs the
32-bit support files to be present.

### Build and run

```sh
make          # build kernel.elf and disk.img
make run      # boot it in QEMU
```

`make` writes `disk.img`, an 8 MiB self-booting image. `make run` boots it with
the serial console on your terminal.

### Check the build

```sh
make check    # boot headless and assert the expected serial trace,
              # drive the command line, and run the host-side agent
```

All three suites should pass: 38 boot assertions, 88 command-line checks, and
the agent suite.

## 3. Put it on real hardware

Two routes, both writing a raw image to a device.

### A. Straight to a pendrive

```sh
make usb                      # build usb.img, 64 MiB
sudo dd if=usb.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with your device. This **erases the whole device**. Confirm
the name with `lsblk` first — writing to the wrong one destroys that disk.

The image boots on BIOS machines. It is a legacy MBR image, so on a UEFI-only
machine with no CSM you must switch the firmware to legacy boot.

### B. Install beside an existing system

`tools/install.py` is a wizard that can take a whole disk, use free space, or
shrink an existing partition to make room. It only moves partition boundaries;
it does not resize filesystems, so it refuses to shrink a partition it cannot
verify is safe unless you pass `--force-shrink`.

Interactive:

```sh
sudo python3 tools/install.py
```

Or non-interactive against a device:

```sh
sudo python3 tools/install.py --device /dev/sdb --mode free --yes
```

To try the wizard without touching a real disk, point it at an image file — this
needs no root:

```sh
python3 tools/install.py --device out.img --create-image 64 --mode whole --yes
```

That produces a 64 MiB bootable image with a SidwaOS partition, which you can
boot in QEMU exactly like `disk.img`.

## 4. The web console and assistant

The browser interface serves the page, a chat assistant, the live telemetry
charts, and the disk download.

```sh
make web      # serves on port 80 and the work-host ports
```

Endpoints:

| Path | What it is |
|---|---|
| `/` | the console page, with the telemetry strip |
| `/api/status` | liveness and version |
| `/api/stats` | one live sample: memory, CPU, disk, link |
| `/api/chat` | the assistant, streamed as server-sent events |
| `/download/sidwaos.zip` | the packaged system |
| `/download/disk.img` | the raw bootable image |

### Connecting a language model (optional)

The assistant answers in three layers: a grounded planner that also runs
commands on the machine, a curated knowledge base, then an optional language
model. The first two need no network and no key, so the chat always says
something true about this machine. The model is last and optional because it is
the only part that can be wrong.

Set three environment variables to attach one. Any OpenAI-compatible endpoint
works:

```sh
SIDWAOS_LLM_KEY=<your key> \
SIDWAOS_LLM_URL=https://api.openai.com/v1/chat/completions \
SIDWAOS_LLM_MODEL=gpt-4o-mini \
make web
```

`SIDWAOS_LLM_URL` defaults to OpenAI's endpoint and `SIDWAOS_LLM_MODEL` to
`gpt-4o-mini`, so a plain OpenAI key only needs `SIDWAOS_LLM_KEY`.

The same three variables drive the host-side agent:

```sh
SIDWAOS_LLM_KEY=... python3 tools/agent.py "how much memory is the kernel using?"
```

For a model running locally with Ollama, point the URL at it. Ollama serves an
OpenAI-compatible endpoint and does not check the key, so any non-empty value
works:

```sh
SIDWAOS_LLM_KEY=ollama \
SIDWAOS_LLM_URL=http://localhost:11434/v1/chat/completions \
SIDWAOS_LLM_MODEL=qwen2.5:3b \
make web
```

The model is never required. Without it the assistant still answers from the
machine's own output and the knowledge base.

## Troubleshooting

**`gcc -m32` fails.** Install `gcc-multilib` and `libc6-dev-i386`.

**"QEMU exited during startup" on the web console.** A leftover QEMU process is
holding the serial socket. Find and kill that specific process:

```sh
ps aux | grep qemu-system-i386
kill <pid>
rm -f /tmp/sidwaos-serial.sock
```

**The image will not boot on a modern machine.** It is a legacy BIOS image. Turn
on CSM or legacy boot in the firmware, or use QEMU.

**The charts are empty for a few seconds.** The kernel is asked for a fresh
sample on each poll, so the sparklines draw as samples arrive. The first CPU
reading can show 100%, which is the boot interval, and it drops to near zero once
the machine is idle.

**A `LOOKUP` the kernel cannot answer.** The kernel tries its own memory and the
`.sidwa` partition, then asks the host agent, which can search the web if
`SIDWAOS_SEARCH_KEY` is set. Without one it falls back to built-in facts, so the
protocol still works offline.

## What runs where

| Piece | Language | Needs |
|---|---|---|
| bootloader, kernel | NASM, C | `nasm`, `gcc -m32`, `ld` |
| `disk.img` | built image | QEMU, or a BIOS machine |
| build tools | Python 3 | `python3` |
| web console | Python 3 + browser | `python3`, a browser |
| assistant | Python 3 | nothing; a model is optional |
