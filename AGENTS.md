# SidwaOS

A minimal, bootable x86 kernel in NASM + C, built around a **3-state I/O
machine**: three cooperative loops that move small programs from execution to
validation to persistent storage. It runs in QEMU and is driven from a serial
command line or from a host-side AI agent.

## Build and test

```sh
make            # build kernel.elf, os.iso, disk.img
make run        # boot in QEMU with the serial console on stdio
make test       # headless boot, assert the expected serial trace (39 checks)
make cli        # drive the command line over a pty (88 cases)
make agent      # run the host AI agent against the kernel (3 cases)
make check      # all three suites
```

`make check` is the gate: every suite boots the real kernel in QEMU and asserts
on real serial output. Nothing is mocked.

## The three states

| State | Loop | What it does |
| --- | --- | --- |
| RUN | `kernel/loop_run.c` | Executes small program fragments on a randomized stack (base + canary), with fast-exit on a corrupt canary. |
| HOLD | `kernel/loop_hold.c` | Parks fragments in a ring buffer and logic-tests them (size + checksum). |
| STORE | `kernel/loop_store.c` | Persists validated programs to disk, gated on a serial key. |

`kernel/state.c` sequences RUN → HOLD → STORE → RUN and collects statistics.

## Bitflow

`kernel/bitflow.c` packs several processes into a single 64-bit flow and splits
them back out. Two entry points:

- `bitflow_combine` / `bitflow_split` — two processes, `4 bit + 4 bit in one flow`.
- `bitflow_combine_many` / `bitflow_split_many` — N processes, high to low.

Widths must sum to at most `BITFLOW_MAX_BITS` (64). Ten processes of 6 bits
(60 bits) pack; ten of 8 bits (80 bits) are refused. There is no 32-bit libgcc
on this toolchain, so no 64-bit division anywhere — see `kernel/console.c` for
the nibble-table formatter.

## AI integration

Two layers, both over the serial line:

- `kernel/ai.c` answers `ask <text>` from the command line. With the bridge off
  it matches keywords locally; with `ai on` it sends the request to the host and
  waits for a reply.
- `tools/agent.py` is the host side. It watches the serial port and replies.

Protocol, one request per line, `\x01` (SOH) marks every control line:

```
kernel -> host   \x01AI <request>\n
host   -> kernel \x01ACT <command> <arg>\n    one or more
                 \x01SAY <text>\n             optional narration
                 \x01END\n                    end of reply
```

The agent's planner has two backends: deterministic rules (default, no network)
and an OpenAI-compatible endpoint when `SIDWAOS_LLM_KEY` is set. Both emit the
same action vocabulary, so they are interchangeable.

## AI auto-debug

`kernel/aidebug.c` runs inside the exception handler. On a fault it prints the
raw machine state, classifies the cause against a fixed table, reports a
suggested fix, and — for survivable faults — skips the instruction and resumes
instead of hanging. Episodes are counted per class.

```
os> debug fault 0
[AIDBG] cause: divide by zero
[AIDBG] fix:   guard the divisor; check the operand is non-zero
[AIDBG] recovery: skipping 2 byte(s) at eip=0x1021d9, resuming
[CLI] survived, quotient=100
```

The same diagnosis goes out on the AI channel, so the host agent sees faults
too. `debug` prints the accumulated record; `debug test` runs the classifier
against synthetic faults.

## Layout

```
boot/       Multiboot entry, GDT/IDT, ISR/IRQ stubs, PIC remap
cpu/        serial (COM1, rx + tx), PIT timer
drivers/    ATA PIO, CPU cache probing
kernel/     kmain, state machine loops, bitflow, console, lib, cli, actions,
            ai, aidebug, know, pedant
include/    headers for the above
tools/      mkboot.py (disk image + bootloader), install.py (wizard),
            parttool.py (MBR/GPT), mkpdf.py (CLI manual), test.sh,
            cli_test.py, agent.py, pedant.py (auto knowledge expansion)
```

## Bootloader and disk layout

- The disk is self-booting: no GRUB. `boot/stage1.asm` is the MBR (entry at
  offset 0) and reads `boot/stage2.asm` to 0x8000; stage 2 enters protected
  mode, parses the kernel ELF and jumps to it with a Multiboot hand-off.
- Both stages have their entry point at offset 0; the `SDB1`/`SDB2` patch
  fields are data and must stay out of the executed path.
- Hand-off structures (`MBI_ADDR` 0x600, `BOOTINFO_ADDR` 0x700) must stay clear
  of stage 2's own 16 KiB at 0x8000..0xC000.
- `mkboot.py` patches the kernel LBA, sector count and `base_lba`. The kernel
  reads `base_lba` from `BOOTINFO_ADDR` via `kernel/layout.c`, so the same
  kernel works whole-disk (base 0) or in a partition (base = partition start).
- `make pdf` regenerates `docs/sidwaos-cli.pdf` from the `help` text in
  `kernel/actions.c`; keep the two in sync by editing only the kernel.

## Conventions

- Formatting: `%s %u %x` only. `%d`, `%p`, width and precision specifiers are
  not implemented in `kernel/console.c` and will print wrong.
- The kernel links `-nostdlib` with no libgcc. Avoid 64-bit division and
  anything else that needs a compiler runtime helper.
- `STORE_LBA` and `STORE_SECTORS` must match between `tools/mkapp.py` and
  `kernel/loop_store.c`, or writes land outside the disk image.
- Disk writes are verified by reading back, not assumed.

## Networking

- The stack (`kernel/net.c`, `drivers/rtl8139.c`, `kernel/pci.c`) is polled and
  single-threaded: waits call `net_poll()` until a predicate holds or the PIT
  timeout expires. There is no interrupt handler.
- Run QEMU with a NIC to exercise it:
  `-netdev user,id=n0 -device rtl8139,netdev=n0`. The `user` backend is slirp:
  10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3. No root, no DHCP client needed.
- Every wait is bounded by `timer_ticks()`, so the network can only be used once
  interrupts are enabled (`sti()` in `kmain.c`). A ping before `sti()` spins
  forever. Boot probes the card before `sti()` and pings after it.
- RTL8139 transmit: the driver writes the **length** to `TSD0..3` to start a
  frame; the card (not the driver) sets the ownership and OK bits on completion.
  Do not write `TSD=0` first: a zero-length write is treated as a real transmit
  and advances the card's descriptor cursor.
- The card walks its four transmit descriptors in turn, so each frame must use
  the next descriptor with its own buffer. Reusing descriptor 0 stalls the
  second frame.
- Bound received payloads by the IPv4 **total-length** field, not the frame
  length. Ethernet pads to a 60-byte minimum, so a short segment (a bare TCP
  ack, a SYN-ACK) otherwise arrives with phantom payload.
- Routing is a single next-hop decision: same subnet goes direct, everything
  else goes to the gateway's MAC with the destination IP left in the header.
- slirp only answers ICMP echo to the gateway itself; pings to outside addresses
  time out even though TCP to the same addresses works.
- Test from the guest over serial, e.g.
  `printf 'net http http://example.com/\r\n' | qemu-system-i386 ... -serial stdio`.
  `example.com` and `info.cern.ch` answer plain HTTP and are good test targets.
- There is no wireless NIC in QEMU and no 802.11 emulation, so there is no
  `wlan0` to drive. Wireless needs a physical adapter or a host-side bridge.

## Reasoning, encoding and the optimised algorithms

- Three modules follow the same shape: an obvious slow algorithm that defines
  the correct answer, a faster one that must produce identical output, and a
  benchmark that proves it. Keep the slow one: it is the reference the fast one
  is checked against, and the gap between them is the lesson.
- `kernel/think.c` (System 2) reasons where `localai` (System 1) guesses. It
  scores every candidate against three kinds of evidence -- rules, model,
  outcome record -- and refuses to act when none is supported
  (`THINK_UNSURE`). It is a pure function of machine state, so the selftest can
  call it without leaving marks.
- The outcome record is weighted to strictly dominate rules plus model
  (`W_RECORD > W_RULE + W_MODEL` in `think.c`). This is deliberate: a measured
  result must beat text-based agreement. Do not rebalance these without a
  reason, and keep the dominance assertions in `think_selftest()`.
- `think_commit()` is the single feedback point: it runs the action, records the
  outcome and trains the model. The CLI and `think_act()` both go through it, so
  a reasoned decision improves the fast path. Bypassing it makes thinking a
  permanent second opinion that never teaches anything.
- Scoring must tokenise once, not once per action: `localai_scores()` is the
  batched form and is ~12x faster than `localai_score()` in a loop, with
  identical results. `think_bench()` measures it at boot.
- `kernel/codec.c` encodes assembled programs. `raw` is a straight copy of
  `struct sasm_insn` (8 bytes each); `packed` is a 16-bit descriptor plus an
  optional 32-bit immediate, and is ~1.6x smaller on real programs. Both are
  byte-aligned on purpose -- a bit-packed stream is smaller and much slower.
- In `codec.c`, `encode_packed_naive()` (one bit at a time) and
  `encode_packed_fast()` (build the word, store it) must emit identical bytes.
  `codec_opt()` checks that and measures the ~11x gap.
- Benchmarks use `tsc_read()` and scale both counts down until each fits 24 bits
  before dividing, so the ratio is plain 32-bit arithmetic with no libgcc.

## Fetch and learn

- `kernel/fetch.c` is the flow that joins the network stack to the knowledge
  cache: fetch a page, clean it to plain text, extract the sentence that answers
  a question, and offer it to `know`.
- It must not break the knowledge cache's rule: a fact reaches `.sidwa` only
  once corroborated. A web page is not corroboration of itself, so
  `fetch_learn()` holds the answer in RAM as unverified and writes nothing to
  disk. `fetch_corroborate()` fetches two sources and persists only when they
  agree. Do not add a path that verifies from a single fetch.
- `fetch_clean()` is rule-based, not a parser: tags dropped, `script`/`style`
  blocks skipped, common entities decoded, whitespace collapsed. Keep it small;
  the output only needs to be plain text because everything downstream scores
  sentences and markup would score as words.
- `fetch_extract()` is a bag-of-words comparison over sentences, three-letter
  words and up, preferring earlier sentences on a tie. It answers "what is X"
  from a defining first paragraph and makes no attempt at anything harder.
- `fetch_answers_agree()` compares folded answers and requires both non-empty:
  agreement on nothing is not agreement. This is the check that protects the
  disk, so the selftest asserts both the agree and the disagree case.
- The cleaning, extraction and corroboration checks are all network-free, so
  they run in the boot selftest. Only `fetch_text()` touches the network; it is
  exercised from the command line (`fetch learn <url> | <question>`).
- Known limitation: extraction needs three distinct question words present in a
  page or it finds nothing. `info.cern.ch` shares too little vocabulary with
  most questions to corroborate against, so pick sources that use the question's
  own words.
- The model starts with zero weights, so `ask` uses the keyword rules until
  enough requests have trained it. `accuracy on built-in set: 0/20` at boot is
  expected, not a fault.

## The pedant: knowing what it does not know

- `kernel/pedant.c` is the machine's critic. Everything else in the kernel is
  content -- knowledge, weights, tallies. This module asks whether the content
  is good enough, and records what is missing. A miss is otherwise silent, and
  silence is indistinguishable from success from the outside.
- Two jobs, kept separate. The *ledger* records questions the machine failed to
  answer, deduplicated with an ask count. The *audit* (`pedant audit`) inspects
  the machine's own state and reports what is weak: open gaps, facts held but
  unproven, actions never used, a model that keeps needing correction.
- `ai_lookup()` is the only place a gap is found: it notes a gap when every tier
  fails, and resolves it when the fact is answered. Resolution happens only on
  the *verified* path, not when an answer is merely held in RAM -- otherwise a
  reboot before corroboration would lose the answer and the record that it was
  ever missing.
- The ledger persists to `.sidwa` under the reserved key `PEDANT`, one record of
  `asks|question;` entries, the same shape the result tallies use. Like
  `OUTCOMES`, it is a reserved key, not a fact: `know PEDANT` returns the ledger,
  a pre-existing quirk of the tallies too.
- `kb_next()` copies bytes but does not terminate them. A scan over the
  partition must set `rec[n] = '\0'` itself, or the tail of the previous record
  is read as part of this one. This is the bug that made the ledger reload as a
  garbled duplicate; `config.c` documents the same trap.
- `tools/pedant.py` closes the loop from the host side. It reads the gaps, turns
  the bridge on (without it the kernel never reaches tier 3), teaches each gap
  via Ollama twice so the kernel corroborates, saves the ledger and the answers
  back into the image, then reboots with no teacher and asserts the machine
  answers unaided. The questions come from the machine; nothing is invented on
  the host side.

```sh
python3 tools/pedant.py --dry-run          # show the machine's open gaps
python3 tools/pedant.py                    # teach every gap it can
python3 tools/pedant.py --model qwen2.5:3b --disk disk.img
```

## Talking to Ollama over the network

- `kernel/ollama.c` is the kernel's own route to a language model served by
  Ollama on the host. It is separate from the serial bridge in `ai.c`: the
  bridge needs a host agent attached to the serial port, this works over the
  virtual Ethernet adapter with nothing attached to the serial line.
- The host is `10.0.2.2`, the address QEMU's user-mode network maps to the
  machine running QEMU. `ollama url <endpoint>` and `ollama model <name>`
  change both; the defaults are `/api/generate` and `qwen2.5:0.5b`.
- The request is a POST of one JSON object via `net_http_post_json()`. The body
  must keep `stream:false` (a streaming reply is many JSON objects the kernel
  would have to reassemble) and `options.temperature:0`.
- `temperature:0` is not a quality choice, it is what makes learning possible.
  The knowledge cache stores a fact only when two answers agree, so a model that
  rephrases itself every time can never corroborate anything and the machine
  would ask forever and learn nothing. Do not remove it.
- `ollama_learn()` applies the same corroboration rule as `ai.c` and `fetch.c`:
  a first answer is held in RAM unverified by `know_remember()`, and a second
  agreeing answer is what calls `know_verify()` and writes to `.sidwa`. It must
  not verify from a single answer, and it cannot write to the partition any
  other way.
- Answers are trimmed to `KNOW_VALUE_MAX` (240) before comparison. The cache
  stores that many characters, so comparing a longer reply against a stored
  record would never match and corroboration would fail for every long answer.
- There is no JSON parser. `extract_response()` scans for the `"response"` key
  and decodes the escapes the models emit, which is enough for the one flat
  object the reply is. The request builder and the reply scanner are
  network-free and run in the boot selftest; only `ollama_ask()` touches the
  network.
- `tools/ollama_teach.py` is the host-side driver of the same flow over the
  serial bridge: ask the machine, ask the teacher on a miss, repeat until the
  machine answers by itself. It measures "before" with the bridge OFF, because
  asking with the bridge on is itself a lesson.

## Machine statistics

- `kernel/stats.c` samples four things the web dashboard charts: memory, CPU
  load, disk speed and link speed. `stats` samples and prints; `stats test`
  checks the arithmetic with fixed inputs.
- Memory is a subtraction, not a reading: the bootloader's memory map gives total
  RAM (`sysinfo_ram_bytes()`), and `_kernel_end` minus the 1 MiB load address
  gives the image size.
- CPU load is **idle accounting**, not a spin test. The kernel has no scheduler,
  so "load" can only mean the fraction of an interval not spent halted. The only
  genuinely idle path is the CLI waiting for a key, which calls
  `stats_idle_wait()` to halt and record the ticks. The load covers the interval
  *since the previous sample*, so the first sample after boot reports the boot.
- Do not replace this with a busy-spin measurement. A spin of N iterations
  finishes inside one 10 ms tick on any real host, so it always reports 100%.
  Idle accounting is the only version that moves.
- Disk speed is measured against the Loop 3 scratch region
  (`layout_store_lba()`), never against the `.sidwa` partition, so a benchmark
  cannot corrupt knowledge. The transfer repeats until at least one tick has
  passed, because a single 16 KiB PIO transfer is under one tick and would time
  as zero.
- Link speed is derived from a gateway ping's round trip, so it measures latency,
  not bandwidth. The PIT resolves 10 ms and there is no calibrated cycle counter,
  so a reply inside one tick reports as "under 10 ms" and the rate uses one tick
  as the lower bound. A big number here would be a lie; a small honest one is
  not.
- `net_ping()` returns **0 ms** for a sub-tick reply, which is success, not
  failure. Check for `< 0` to detect a timeout; treating `0` as failure makes a
  working link report as down.

## Timers and the bridge timeout

- `cpu/timer.c:timer_sleep_ms()` rounds up to at least one tick. At
  `PIT_HZ=100` a tick is 10 ms, so `(ms * PIT_HZ) / 1000` truncates any request
  under 10 ms to zero and returns without sleeping.
- That truncation silently broke the AI bridge: `read_host_line()` polls in 5 ms
  steps against a 6 s budget, so every step returned instantly and the whole
  budget expired in microseconds. The kernel gave up before the host could
  answer, and every lookup logged `no answer ... from any tier` while the reply
  arrived a moment later and was read as console input (`unknown command: KNOW`).
- Do not "fix" a bridge timeout by raising `AI_WAIT_MS`; the sleep itself is
  what was wrong. A delay sweep in `tools/ollama_teach.py` (0.0 s works, 0.1 s
  fails) is the quickest way to tell the two apart.

## Web interface

- `web/` is the browser front end. `make web` serves it; the ports come from
  `SIDWAOS_WEB_PORTS` (default `80,12000,12001`, the public work-host ports).
  One QEMU instance backs every listener, so all URLs reach the same machine.
- `web/runtime.py` owns the only path into the kernel: a Unix socket on QEMU's
  serial line. It both streams the log and types commands, so a command from the
  page and one typed by hand behave identically. Keep it that way -- do not add a
  second way in.
- `runtime.run_command()` serialises commands under a lock. The kernel has one
  console, so two concurrent writers would interleave and neither would get a
  clean answer.
- `web/ai.py` answers in three layers, and the order matters: a grounded intent
  planner that also runs the chosen command, a curated knowledge base, then an
  optional language model (`SIDWAOS_LLM_KEY`). The first two need no network, so
  the chat always says something true about this machine. The model is last and
  optional because it is the only part that can be wrong.
- Explanations and actions take different paths. "How does the thinking
  algorithm work?" is answered from knowledge; "run a cycle" drives the machine.
  `is_explanatory()` decides, and the two branches prefer different sources.
- The kernel's output is shown verbatim in the evidence block, so the prose does
  not repeat it. Do not paste command output into the reply text as well.
- A finite SSE stream (the chat reply) sends `Connection: close` and closes, or
  the client waits forever for an end that a stream never signals. The live log
  is open-ended and stays connected.
- `web/index.html` is self-contained: page, CSS and JS in one file, no build
  step. It classifies log lines by their `[TAG]` and drives the RUN/HOLD/STORE
  indicator from the kernel's own `[STATE] a -> b` transitions, so the panel
  shows what the machine is really doing.
- The runtime runs from a copy of the disk (`run.img`) so a browser session
  cannot leave the canonical `disk.img` dirty. `/download/disk.img` serves the
  canonical image.
- `/api/stats` runs `stats` on the kernel and parses the `[STATS]` lines back
  into JSON for the telemetry strip. The kernel owns the numbers; the endpoint
  only reads them, so the chart and the console can never disagree. Missing
  fields are omitted rather than zeroed, so the page can tell "not measured"
  from "measured as nothing".
- The telemetry strip (`web/index.html`) keeps a 40-sample history per metric and
  draws each as a sparkline. A flat line at zero sits on the floor, not
  mid-panel. CPU is charted against a fixed 100% scale so the line's height means
  something; the others auto-scale because their absolute size depends on the
  host.

## Launching under QEMU

- Every launch path must attach the network card. The kernel's driver is
  correct and reports what it sees, so a QEMU command line without
  `-netdev user,id=n0 -device rtl8139,netdev=n0` boots a machine with an empty
  PCI bus and the kernel truthfully logs `no RTL8139 on the PCI bus` /
  `no network card found`. That is a missing device, not a driver fault; do not
  "fix" it in `drivers/rtl8139.c`.
- The five launch paths are `Makefile` (`make run`), `tools/test.sh`,
  `tools/agent.py`, `tools/cli_test.py` and `web/runtime.py`. They must agree.
  `tools/test.sh` asserts `NET] RTL8139 at`, `NET] MAC` and
  `NET] gateway selftest: ok`, so a launcher that drops the device now fails the
  suite instead of silently booting without a network.
- Tests that write to the disk run on a scratch copy (`cli_test.img`,
  `run.img`), never on the canonical `disk.img`. `cli_test.py` changes the
  `.sidwa` grade, writes records and saves model weights, and asserts the grade
  it started from; on the shared image the second run inherits the first run's
  state and fails. Copying is what makes the suite order-independent.
- `tools/cli_test.py` reads the built-in set size from `kernel/localai.c`
  instead of hardcoding it. The accuracy numerator (15) is the regression
  signal and is deliberately fixed; the denominator is a moving target and is
  derived. Adding a training example should not require editing the test.

## Packaging

- `make zip` (or `tools/mkzip.py`) writes `sidwaos-<version>.zip`: every source
  file plus the built `disk.img`, so the system can be run without building.
  `make zip` depends on `pdf`, so the shipped manual is never stale.
- The archive holds the system and the recipe for it, and nothing either of
  those produces. `SKIP_PATHS` and `SKIP_SUFFIXES` in `tools/mkzip.py` list what
  a build regenerates or a run leaves behind; `INCLUDE_BUILT` names the one
  deliberate exception, `disk.img`. Add to those lists rather than writing new
  filtering logic.
- The zip is deterministic: sorted entries and a fixed timestamp, so packaging
  the same tree twice gives identical bytes. Do not introduce a real timestamp
  or `os.walk` order into it.
- `disk.img` is 8 MiB but almost all empty, so it compresses to about a tenth of
  a megabyte. That is what makes a no-build download cheap; it is not a reason to
  drop it.
- `/download/sidwaos.zip` on the web interface serves the same archive, building
  it once on first request behind a lock. `/download/disk.img` serves the raw
  image.
- A change to what ships should be checked by extracting the zip to a clean
  directory and running `make` there, not by trusting the file list.

## Improvisation: writing and improving programs (synth, peephole)

- `synth <task> => <expected output>` asks the model for a program, then decides
  whether to believe it by assembling, running and comparing the output. The
  arrow separates the task from the expected output; no quoting is needed.
- The gate is the whole point. A program can be checked in a way a sentence
  cannot, so a wrong answer cannot pass as a right one. Only a program that
  assembles, runs, finishes and prints exactly the expected output is stored.
- Inputs are baked into the generated source as constants. The ISA stays at 12
  instructions: adding an input instruction would change the language every
  existing program is written in. Do not add one.
- `ollama_ask_code()` in `kernel/ollama.c` is a second path to the model, separate
  from the prose `ollama_ask()`. The prose path asks for "one short sentence",
  collapses whitespace and trims to 240 characters -- all three make a good
  knowledge-cache record and all three destroy a program. Use the code path for
  code, the prose path for facts.
- The ISA prompt in `kernel/synth.c` must name every instruction. A truncated
  prompt makes the model invent x86 (`MOV EAX, 20`, `INT 0x21`). `synth_selftest()`
  checks the prompt against `sasm_op_name()`, so adding an instruction without
  updating the prompt fails the selftest.
- The assembler appends `HLT` to a program that does not end in one. Running past
  the last instruction means the program is over, as in every assembly language.
  This was found by synthesis: the model wrote a correct program and it was
  rejected for running off the end.
- A task solved once is stored under the task and answered from `.sidwa` next
  time with no model call. A recalled program is re-run, not trusted, since it
  may have been stored by an older assembler.

### Optimisation (kernel/peephole.c)

- The measure is VM steps, not wall-clock time. Every instruction costs exactly
  one step, so a shorter program is a faster one and that is checkable. Never
  claim a wall-clock speedup.
- Three local rewrites, repeated to a fixed point: fold `MOV rX,a` + `ADD/SUB/MUL
  rX,b` into one; drop identities (`ADD/SUB rX,0`, `MUL rX,1`, `MOV rX,rX`); drop
  a `JMP` to the next instruction.
- Two invariants keep it correct, and both are easy to break. Jumps hold absolute
  addresses, so every jump target must be rewritten through the old-to-new map
  when an instruction is removed. And any instruction a jump lands on must be
  pinned and never removed. `peephole_selftest()` covers a loop whose body
  shortens, which is where both mistakes show up.
- The shortened program is re-run and its output compared with the original's
  before it replaces anything. A rewrite that changes the output is a bug, and
  this is where it is caught.
- An optimised program cannot be stored as source directly, because its jumps
  hold absolute addresses. `peephole_render()` gives every jump target a label
  (`L<address>`) again. The rendered text is reassembled and checked for the same
  length before it is stored, or the text on disk would not reproduce the program
  that was verified.
- The saving is stored as knowledge under `optimise: <task>`, e.g. "removed 1 of
  4 (4 -> 3 steps): fold 1, identity 0, fall 0", so the record survives a reboot.
- `sasm_disasm_one()` had a latent bug: it dropped the destination register and
  printed `MOV 1` for immediate and register operands. Nothing used it before the
  optimiser did. If you extend it, check the operand order: data-processing forms
  print `OP rDst, src`; the STORE form prints `MOV [rDst], rSrc` and must not get
  the destination prefix twice.

### Testing synthesis

- The kernel's HTTP timeout is shorter than a cold model load. Warm the model
  before booting (`curl .../api/generate` with the same model), or the first
  `synth` fails with "model unreachable" and 65 bytes.
- The CLI reads one line at a time, so a multi-line expected output cannot be
  typed at the prompt; test multi-line cases through `synth_selftest()` instead.
- `make check` must stay green; the synth and peephole selftests are required
  trace lines in `tools/test.sh`.

### Text, timeouts, and retries

- **The HTTP timeout is a bug generator, not a safety net.** A model computes
  its whole reply before sending the first byte, so with `stream:false` a
  request that is working fine sends nothing for as long as it is thinking.
  Generating a program (not a sentence) took about 45 s on qwen2.5:3b, and the
  old 30 s ceiling / 8 s idle window cut every program request off mid-thought
  and reported "model unreachable". The client was misreading "still working"
  as "gone away". `net_http_request_timed()` takes `ceiling_ticks` and
  `idle_ticks`; the code path uses `OLLAMA_CODE_CEILING_TICKS` (120 s) and
  `OLLAMA_CODE_IDLE_TICKS` (60 s). If a model request ever fails with
  "unreachable", check the clock before the network.
- **Character literals exist** (`'H'`, `' '`, `'\n'`), added because asking the
  model for ASCII codes failed predictably: it wrote 'H' as 7, 'W' as 44, 'e' as
  88. A literal compiles to the same immediate a decimal does, so the ISA is
  unchanged. `read_token()` copies a literal verbatim (no lowercasing) and
  `parse_char_lit()` handles the escapes; malformed literals (`'ab'`, `''`,
  unterminated) must be rejected, not silently misread. Do not remove the
  lowercasing bypass: 'A' and 'a' are different values.
- **Retries must carry the verifier's finding.** Temperature is pinned to 0, so
  an identical retry returns an identical wrong program. `synth_write()` tries
  `SYNTH_ATTEMPTS` (3) times, and each retry after a mismatch uses
  `synth_prompt_retry()` to quote back what the previous program printed. This
  is safe only because the gate runs on every attempt -- a wrong program cannot
  be stored. Retries are pointless without feedback and unsafe without the gate;
  both halves must stay.
- **qwen2.5:3b drops the last character** of a string task (writes "Hello Wor"
  for "Hello World"). Telling it the last character in the prompt makes it
  *worse* -- it prints only that character. The fix that works is a worked
  `MOV`/`OUTC` example in the prompt plus the feedback retry; measured 10/12 on
  short strings, and end-to-end it recovers on attempt 2.
- The synthesis selftest asserts the prompt teaches literals and that the retry
  prompt keeps the task, the output and the language. Extend it when the prompt
  changes.

### Showing the wait

- **A silent wait is read as a hang.** Asking the model takes ~45 s and
  `stream:false` returns everything at the end, so the machine printed nothing
  for the whole wait. That got misdiagnosed as a hang twice: once by a user
  reading the screen, once by the HTTP client. When adding anything slow, make
  it report itself.
- `net_http_request_progress()` / `net_http_post_json_progress()` take an
  optional `net_progress_fn`, called at the start and then **once per whole
  second** (not per poll -- the loop spins thousands of times a second). `net.c`
  stays model-agnostic; the caller decides what to show.
- `ollama_thinking_begin/tick/end` print `[OLLAMA] thinking: the model ... 7s`
  on one line that rewrites with `\r` and is cleared when the reply lands. The
  opening line uses `klog()` (newline, survives in the log); the ticks use
  `kprintf()` with `\r` (no newline, so a minute costs one log line, not sixty).
  Do not switch the ticks to `klog()`.
- The indicator writes through the **console sink**, not `serial_putc`, so the
  GUI log mirrors it. The GUI sink now treats `\r` as "restart this line"; only
  `\n` commits a line, so a cleared spinner never appears as text. This matters
  for anything written in place.
- The `ollama` selftest captures the indicator's output via `console_set_sink`
  and asserts in-place rewriting, elapsed seconds, and the opening newline.

### Asking for algorithms (Fibonacci)

- **qwen2.5:3b cannot improvise a loop.** Asked for 15 Fibonacci numbers it
  invented `ADD r2, r0, r1` (three operands, which the ISA does not have),
  emitted `OUTC '0'`, and used no loop at all. This is not a bug to fix; it is
  the boundary of the improviser. The answer is to teach it, not to widen the
  ISA.
- **What the prompt must contain for a loop task:** the two-operand rule with a
  worked example (`r2 = r0 + r1` is `MOV r2, r0` then `ADD r2, r1`), a
  fixed-count loop example (counter, `SUB`, `CMP`, `JNZ` back to the label), and
  the algorithm's register plan. With those three present the model wrote
  correct Fibonacci 2/2; with only a loop example it wrote an infinite loop, and
  with a vague hint it dropped the counter entirely.
- Naming the last character, or otherwise over-specifying the answer, makes
  results **worse** (see the text-prompt note above). Give the shape of the
  method, not the answer.
