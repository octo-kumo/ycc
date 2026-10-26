# AGENTS.md — y compiler

The contributor guide: how the tree is laid out, how to build and test it, and
the rules a change follows. It is written for people and coding agents alike.

`src/y/` is the compiler, with its own x86-64 assembler and ELF/PE writers.
`bootstrap/ycc.c` is a generated GNU99 seed; `src/c/` contains only its value
and host runtime. Maintain compiler passes in Y and refresh the seed with
`make bootstrap-update` after the self-compilation gates pass. See `PORTING.md`.

## Build

- `make help` lists every target. Scripts and recipes make their scratch space with
  `mktemp -t` (so `$TMPDIR` is honoured) and clean it up; never a fixed `/tmp` name. A
  `test/y/native` fixture that writes files starts with `// scratch` and uses relative
  paths: the harness runs it in a scratch directory.
- `make` → `./cycc` (the generated C seed).
- `make ycc` → builds `./ycc` with `cycc`, attaches the pack stub and the std
  pack — `base || STUB || LEN8 || "YCCSTUB1" || stdpack || LEN8 || "YCCPACK1"`,
  the stub's frame first so the std pack keeps the last 16 bytes — then verifies that `./ycc` self-compiles to the same bytes.
  `make pack-bench` reports what `--pack` costs (see Run / verify).
- **Windows is tested on a real Windows machine, never under wine** (wine is more
  lenient than the kernel about alignment, import tables and syscall numbers, so a
  program can pass under it and not start on Windows). The PE runs are therefore not
  in `make test`: `make pe-test` (`ytest pe-gate pe-packinv pe-fixtures`) and `make
  pe-cycc` (`ytest cycc-win`) send them to the machine named in the git-ignored
  `.pe-vm.conf` (`pe-vm.conf.example`; ssh plus a directory both sides see, or
  `backend = local` on a Windows host, where `make` picks that by itself). Run them
  after touching `pe.y`, `arch/w*.s`, `os_call` names or a std unit's Windows path;
  they are not run on every change, so a PE regression can sit unseen until then.
  `make cycc.exe` cross-builds the generated seed for Windows with mingw; `pe-gate` and `pe-port`
  need no Windows machine (headers, import table, byte-identical C seed).
  **Every std module runs on the Windows target** (threads, `fork`, `exec`/`popen`,
  sockets, `net`/`http`/`tls`, `ipc`, `tui`, `snd`, `gui`, `fs.getenv`, `argv`):
  `pe-fixtures` ends with no PE-only failure.
  Where the platforms rightly differ a fixture says so in a file beside it:
  `NAME.skip.win` (the text is why: it tests something Windows does not have, e.g.
  the raw Linux `syscall`, symlinkat, a POSIX shell, or takes an hour there) or
  `NAME.expected.win` (what the PE prints instead; `t415_snd` assumes a machine with
  no sound device). `test/pe/NAME.args` / `.env` give a program its raw command
  line and environment. How: nothing in a std unit reaches the kernel
  except through `os_call("y_os_…")` (a raw `syscall` in a packed unit would bake
  the HOST's argument convention; a user program's own `syscall` is the host OS's
  numbering, NT on a PE). The Windows half of every name is in
  `src/y/arch/wsys.s` (NT direct syscalls), `wproc.s` (fork, spawn, wait, pipe),
  `wnet.s` (Winsock), `wcon.s` (console, waveOut), `wgui.s` (a call into user32/gdi32
  and the window procedure, below) and `wthreads.s` (the thread runtime). DLL functions beyond the two the PE imports (`LoadLibraryA`,
  `GetProcAddress`) are looked up on first use (`y_w_api`, cells of `yw_apis`), so
  a program that opens no socket never loads ws2_32. A PE runs the NT syscall
  self-test at startup (`arch/wselftest.s`), so a drifted `w_sysno` fails loudly
  instead of calling the wrong Nt function; the numbers that move between Windows
  builds are not pinned (`NtQueryFullAttributesFile` is read out of the running
  ntdll, `y_w_sn_attrs`; the system time comes from KUSER_SHARED_DATA). **What a
  real kernel enforces and wine does not:** 8-byte alignment of every pointer
  argument of an Nt call (a frame slot for a handle, an `OBJECT_ATTRIBUTES` or an
  out-buffer at an offset that is not a multiple of 8 fails with
  STATUS_DATATYPE_MISALIGNMENT), a 16-byte aligned stack at a call into a DLL, and
  an IAT that starts non-zero (the loader measures it by walking to the zero
  terminator, so the `.bss` head that holds it is file-backed and prefilled with
  the hint/name RVAs: `pe_bss_raw`, `pe_iat_image`).
  What differs from Linux, by design: a socket handle is the descriptor; there is
  no `fork` in Windows, so `fork` starts a copy of the executable and copies the
  heap into it at the same addresses (`wproc.s`), and the child inherits only
  inheritable handles; the shell is `cmd.exe /d /s /c`; file modes are the
  READONLY attribute; `tui` needs a console (virtual-terminal input and output
  are switched on) and has no watchdog child; `snd` plays through waveOut; a
  refused loopback connect takes about 2 s.
  **Windows.** `std/gui.y` is a window on a desktop (one API, no `#ifdef`: `gui.open`
  answers a Win32 window on Windows, an X11 one under an X server, `open_headless` a
  buffer): `gui.pixels` are the client area (B G R A), `gui.cell` rasterises a text
  cell from a baked bitmap font (`gui.font`, from `src/tools/guifont/mkfont.py`, an
  `embed` of the unit that `std_embeds` expands when the unit is compiled, and a `STD_SRCS`
  entry so a re-baked font rebuilds the pack;
  box drawing, blocks and braille are drawn from rules), `gui.poll` returns key, char,
  mouse, resize, focus and close events. The Win32 half is Y over three names
  (`y_os_gui_sym`, `y_os_gui_call`, `y_os_gui_wndproc`: a symbol lookup, a call with a
  block of arguments, the address of the window procedure); the window procedure is
  asm (`wgui.s`) that only queues `(hwnd, message, wparam, lparam)` into a ring Y owns
  and tail-calls `DefWindowProcA`, because it runs on a foreign frame the collector
  scans (WM_CLOSE, WM_ERASEBKGND and a menu key are answered there). X11 is the wire
  protocol over `ipc` (no libX11). A GUI program sets `subsystem = "gui"` in the `[package]` table of `y.toml`:
  no console, so stderr goes to a file
  (`gui.redirect_stderr`). `ycc build --target=win` writes `build/win/NAME.exe`.
  **A window's DC is not readable from an ssh logon** (session 0 has no visible
  desktop): `verify_present` blits into a memory bitmap and reads that back, which any
  session can do; to see or drive a real window run the program in the logged-in
  desktop (a scheduled task with `/it`) and use PowerShell for keys, the mouse and a
  screenshot. `StretchDIBits` of a top-down bitmap counts source rows from the
  bottom: `w32_blit` hands it the bits from row `y0` and a source y of 0.
- `make yserve` → the language server; `cycc` and `ynew` (current Y sources)
  must produce it byte-identically. `make lsp-ext` / `lsp-vsix` build the
  VS Code extension.
- `make ytest` → `./ytest`, built by native `ynew` (`src/tools/ytest/`; falls
  back to `cycc` when `BOOT` is absent): every suite,
  gate and measurement tool in the repo, in Y — `./ytest help` lists them. No
  shell drivers remain besides `test/sh/capped.sh`.
- Never commit artifacts: `*.o`, `cycc`, `cycc.exe`, `cycc-asan`, `ycc`, `_ycc*`,
  `ynew`, `ytest*`, `*.pack`, `a.out`, `_check/`, `_ktmp/`. `refs/` is gitignored
  and is **not** disposable: it holds the blessed reference compiler
  (`refs/ycc.ref`) every comparison is made against. A fresh checkout has
  none; the first `make ynew`/`make test` seeds it from `./ycc`, and
  `make rebless` replaces it.
- **No std source is embedded in the compiler.** Every `src/y/std/*.y` is a
  unit compiled into the std pack attached to `ycc` (the four core units and the
  twenty-nine library modules alike (`kmem`, `yfs`, `fd` and `kernel` among them: `ycc --target=kernel` needs no checkout either); `STD_SRCS` in the Makefile makes an edit
  rebuild every packed binary) — edit them directly; there is no generator, and
  `str.y` holds no string literals. A source is read from disk (`src/y/std/`,
  or `std/` beside the binary: native.y `std_lib_path`) only to build the pack,
  under `--std=source`, and by a compiler with no pack attached (`cycc`, a bootstrap
  generation) — so a packed `ycc` does **not** see an edit to a std file until it
  is rebuilt; test one with `cycc`, `--std=source`, or `make ynew`. A project-local
  `name.y` (beside the importer or in a package root) shadows the std unit
  `name`.
- **The runtime assembly is not embedded either.** `src/y/arch/*.s` is cut into
  blocks of IR once (native.y `arch_blocks`: one per column-0 label, a line an IR
  form reproduces exactly as an item, any other line as raw text) and the std pack
  carries the blocks (`arch.linux`, `arch.win`, `arch.wselftest`,
  `arch.threads`, `arch.wthreads`, `arch.math`); a compile decodes only the blocks it keeps. The
  files are read from disk (`arch_src`) only to build the pack or by a pack-less
  compiler, so the same rebuild rule as for `std/` applies (`ARCH_SRCS`).
  Whole-line `#` comments are dropped before the in-tree assembler sees them;
  `make asm-check` checks the files with GNU `as`.
- **Under 4 GB of memory, always** — a runaway compile must fail with "out of
  memory", not take the machine down. The Makefile
  runs recipes through `test/sh/capped.sh` (`ulimit -S -v 3670016`); by hand,
  `(ulimit -v 3670016; timeout … cmd)`, valgrind/gdb/perf included. Hitting the
  cap is a bug to fix, never a reason to raise it.
- ASan has its own cap (`make asan`, `make test-asan`,
  `ASAN_OPTIONS=hard_rss_limit_mb=3500`); programs a sanitized compiler emits
  still run under the normal one.

## Changing the compiler

1. Change `src/y`, add fixtures and docs. Use native `make ynew ytest` for
   development; refresh the generated C seed after verification, at a bootstrap
   checkpoint rather than after every edit.
   `make fmt` formats `src/y`, `src/y/std` and `src/tools/lsp` **in place** with
   the editor's formatter (`src/tools/lsp/fmt.y`, LSP.md R3); `make fmt-check` is
   the gate — **idempotence** over the tree (0 non-idempotent) plus a `src/y`
   fixed-point count that is a signal, not a gate (files that differ follow the
   formatter's deliberate author-layout policy, LSP.md R3.6, so run `make fmt`
   only when the reformatting is wanted). A buffer
   the scanner cannot lex is skipped, never mangled. `src/c` is not formatted: it
   is a Y formatter.
2. Daily feedback: `timeout -k 5s 60s make ynew ytest </dev/null`, then run the
   relevant suites with the native compiler, for example
   `CYCC=$PWD/ynew YREF=$PWD/ynew YCC=$PWD/ynew timeout -k 5s 60s ./ytest -j4 native ycc </dev/null`.
   This checks fixture expectations; it does **not** check C/Y parity. Keep the
   old reference until any intended behavior/code differences have been reviewed
   (`make corpus-diff FILES="..."`, `make bench`).
   `make check` is the explicit, slower complete measurement — builds `./ynew` from `src/y` with the blessed compiler
   (generations 2 and 3 byte-identical), requires `cycc` to build it byte for
   byte, runs the fast suites with it as the reference, then compares with `BASE`
   (`refs/ycc.ref`): programs that compile or behave differently, benchmark
   instruction counts, and the SCORE. **Read every difference it lists.**
   Run the relevant slow suites explicitly, or `make test-all` for all 31.
3. `make rebless` — native development bless: builds `ynew` from `BOOT`, checks
   generations 2 and 3 are identical, runs the `native` and `ycc` regression
   suites with native Y, then installs `refs/ycc.ref` (+ `./ycc`,
   `refs/SHA256SUMS`). The **whole target, including prerequisites, has a 60 s
   timeout** (`REBLESS_TIMEOUT`); a failed build or suite never installs a reference.
   No C seed build or C corpus sweep runs here.
4. At a bootstrap/release checkpoint, run
   `timeout -k 5s 120s make bootstrap-update </dev/null` and
   `make rebless-full`: the latter retains the C-seed self-compile/fixpoint and
   exhaustive Linux/PE C/Y port gates before installation. These are explicit
   slow audits, required after changing the C generator/runtime or refreshing
   the seed; they are not the per-edit loop. `rebless-full` has a 120 s limit
   (`REBLESS_FULL_TIMEOUT`). Commit with the relevant verification numbers.

Standalone: `make ynew`, `make port-check` (failures only), `make corpus-diff`
(`FILES="a.y b.y"` narrows it), `make bench`, `make bench-ir`. On 8 cores
`make -B rebless` takes about 9 s, including rebuilding native Y and `ytest`;
the full C audit (`rebless-full`) about 70 s. The full bless builds the std
pack once with C, compares it with the native one, and reuses it for every
port check. Keep native `rebless` as the daily loop. `make check`,
`make port-check` and `make test-all` can take many minutes.
**Do not start these unbounded during development.**
Give every command a timeout and stdin from `/dev/null`; use 60 s for the native
loop. A timeout is a failure to investigate, not a reason to rerun with an
unbounded wait. Run a slow audit deliberately with an explicit larger budget
when its coverage is needed.

**Performance.** Anything that can move compile time, output size or program
speed gets `make check`'s numbers plus `make bench` in the commit message. A
SCORE within 100 ± 2.5 is no change; instruction counts are exact. Explain what
moved with the callgrind table, `perf`, or `ycc --time`.

## Run / verify

- `./ycc f.y -o /tmp/b && /tmp/b`; the same through `./cycc`; `./ycc --emit=asm f.y`.
- `--gc=never|auto|always|stress` (default `never`): checked lifetimes, with no
  collector unless explicitly enabled. `lifetime.y` propagates allocation,
  repetition, heap-bypass and unknown-call effects through call cycles and
  callbacks; versioned effects travel in `Unit.fx`. Unproved reclamation is
  an error. Escape-proved loops and scratch-only functions get regions;
  finite setup allocations and geometric array growth are allowed.
  `--gc=auto` opts in and omits GC where no repeated allocation is possible;
  `always` forces it; `--gc=never` is checked, and `--gc=stress` is its own mode.
  Native compiler build recipes use `--gc=never`; its process-ending entry
  region owns shared pass state until exit, with temporary inner regions.
  Tool recipes still use `--gc=auto`. The legacy test
  corpus does too (`yt.cmd`, `yc.compile`); the `lifetime` suite uses
  `yt.raw_cmd` to test the public default. `--gc=stress` opts in and runs a cycle at *every* allocating
  slow path — the collector's own test (a missed root shows up as a crash in
  minutes, not days), used by the `gc` suite, and a very slow build.
- The heap report (`heap: ...`, at `-W 1`/`extra` and above) warns at every
  allocation that repeats — in a loop, or in a def that is recursive, called
  in a loop, used as a value or called by one of those — with nothing to free
  it: a report only (lint.y `lint_heap`, fed the call/operator types by
  types.y `heap_index_on`). Bytes unchanged; it is part of the extra/all
  warning level so a default build stays quiet.
- `region { .. }` frees everything its block (and its callees) allocated when
  it ends; `heap { .. }` allocates outside every open region (what must
  outlive it: a std unit's cache, a kept copy). Parsed as the internal calls
  `region$`/`heap$` (contextual words: only at a statement's start before
  `{`); runtime in arch/regions.s (an arena with regions as marks, the record
  in the frame; `heap` goes through hooks the first region installs); one
  thread only. A `break`/`continue`/`return` out of one releases it
  (native.y `gen_rg_leave_to`). escape.y checks that nothing made in a region
  outlives it (per-def summaries, std's in the pack: `Unit.fx`) and wraps
  every loop body that passes in `region$auto`; with GC enabled an automatic arena past 32 MiB is handed to the
  collector (`y_region_spill`). Checked builds disable this fallback and
  keep reclaiming large turns.
- `ycc run f.y` compiles and runs in one step; `ycc --emit=source f.y` dumps the source the
  pass saw (meta blocks expanded); `ycc build` / `ycc vendor` for `y.toml`
  projects.
- `--ob` is the opt-in obfuscation mode, and there is one level:
  the bare flag and `--ob=full` both select the strongest preset.
  It transforms the program's own IR at final link
  (`obfuscate.y`: constant splitting, frame shifts, opaque junk, indirect
  calls, shuffled blocks, dead bodies, shuffled literal/global pools, dense
  diversity), seals the image and
  starts it through a plaintext page (`seal.y`, `asm_link`), makes code pages
  decode lazily on SIGSEGV (runtime messages are decrypted eagerly, because a
  syscall reading a PROT_NONE page gets EFAULT rather than a signal; literals
  and the bytecode after `y_obf_data_start` are decrypted page by page, and a
  literal use touches one byte per page first), and compiles
  eligible helpers (frame, heap/global/closure memory, x86-64 calls) into
  generated bytecode with per-function opcode maps, run by a native
  interpreter (`obf_vm.y`). `--ob-key=PATH` implies full and keeps the
  stream key out of the binary; a missing or wrong key fails before `_start`.
  `--ob-key-fd=N` reads that key from descriptor N, so a launcher can
  pass an anonymous pipe instead of a path. `tools/keyserver/` is a
  server/launcher prototype that hands a sealed binary its key (X25519, direction-separated ChaCha20-Poly1305
  with AEAD-encrypted licence proofs, per-user licence HMACs, a pinned RSA
  server signature, binary-hash allowlist, persistent client-nonce store,
  connection timeouts and a global failure rate limit); it also has an optional
  TPM 2.0 quote path (`tpm2_checkquote`, PCR allowlist, client nonce), verified
  with `swtpm`; it is not TLS and hardware TPM/SEV/TDX verification needs the
  deployment host. `tools/remote/` is a remote-execution prototype
  (token-authenticated argv/stdin with per-argument quoting, multi-token files,
  persistent nonce replay refusal, CPU/address-space/file limits, a 15 s timeout
  and 60 KiB input/output caps; no OS isolation yet). Each tool's usage is in
  the header comment of its `server.y`/`client.y`; `tools/keyserver/selftest.y`
  runs the protocol end to end. `tools/obf-audit/audit.py` is the external
  checker behind `make obf-audit` (`scan`, `tamper`, `gdb`).
  `--ob-seed=N` is reproducible; `--ob-report` prints a build id and counts;
  `--ob-map=PATH` writes a label/address map outside the binary. There are no
  strength knobs: body order is shuffled, every std body is rewritten, the
  per-function opcode maps use the high diversity setting, and the bytecode VM
  and anti-debug checks are always on. A keyed hash of the sealed ciphertext refuses a modified
  file; each cipher page also has a keyed MAC in the plaintext loader table,
  and the fault handler checks the decrypted page at first touch (a changed
  entry or a page patched before use exits 139; a patched loader can skip the
  check, and memory patched after first use is not rechecked). A key-derived
  canary replaces the fixed magic; full mode reads TracerPid (it must not
  become a tracee, or lazy faults would go to the tracer).
  Obfuscation covers Linux ELF and Windows PE: a PE build gets the static pass, the flatten
  layer (the bytecode interpreter is SysV-flavoured, so `bytecode` means
  flatten there), a plaintext entry stub that decrypts code and `.rodata` in
  place in a writable `.text`, a keyed image hash and `IsDebuggerPresent`;
  its key is embedded (no `--ob-key` on Windows), there are no lazy
  pages or per-page MACs, and anti-debug is a patchable speed bump. It refuses
  `-g` and also `--pack`, `--emit=asm`, `--emit=source` and `--target=kernel`. The meta generator, the pack stub and package objects
  run with the pass suspended. `ytest obf` is the slow suite; t900-t913 in
  `test/y/native` are the daily smoke test. The mode is obfuscation, not a
  cryptographic boundary: keys are recoverable, the cipher and loader are
  per-build and page-keyed (there is no plaintext salt table), and
  the anti-debug checks are a patchable speed bump, not anti-VM or tamper
  proof; `make obf-audit` runs the external scan/tamper/gdb checks; the
  bytecode gets an additional per-function xor and the flatten layer
  has two dispatch hubs and a bogus state.
- `--pack[=METHOD]` writes a self-decompressing binary: a stub
  (`src/y/packstub.y`), the compressed program and a `YCCPACK2` trailer; the stub
  decodes the payload into a memfd and `execveat`s it, so argv, the environment,
  the descriptors, the pid and the exit status are the payload's own. FILE may be
  Y source or an existing executable (`ycc --pack ./ycc`); a payload that carries
  a std pack has it stored PLAIN first, so the codec sees the pack text. METHODS:
  `dynamic` (the default: 64 KiB blocks, lazy matching, a heap-built Huffman
  tree per block), `store`, `fixed`, `lz`.
  `make pack-bench` prints the sizes method by method, the external compressors'
  floor and the startup cost (the whole payload is decoded before every run:
  measured ~35 ms more per invocation on ycc). Linux ELF only.
- `./ycc --time f.y` prints a phase table to stderr. Builtins: `clock_us()`,
  `heap_used()`, `eputs(v)`.
- `-g` adds symbols, DWARF and section headers (code unchanged), so `perf`,
  `valgrind --tool=callgrind`, `gdb` (`break file.y:N`, no variables), `nm` and
  `addr2line` name things.
- Always feed `</dev/null` in scripts.
- **A built `ycc` is self-contained.** All thirty-four std units (33 plus `gui@web`) travel precompiled
  in the std pack attached to the binary (pack 11: each unit stored and
  compressed on its own with its decoded length, so a compile decodes only the
  units it links, each in one pass), so a
  copy in an empty directory compiles `import fs`/`net`/`args`-style programs
  with no source anywhere. A lone `ycc --std=source` has nothing to compile from and
  says so.

## Tests

`make test` runs the 15 fast suites, `make test-slow` the 16 slow suites, and
`make test-all` all 31 (`./ytest -j4 all`; `./ytest -j4 port native` for a subset).
They take `CYCC`, `YREF`, `YCC`,
`YSELF`, `YQUIET` and `YPORT_SELF` from the environment.

| suite | what it pins |
|---|---|
| port | every `test/y/**.y` compiles to identical bytes under `cycc` and the reference, with the same warnings |
| pe-port | the same for `--target=win`, with and without `-g` |
| native | `test/y/native/t*` (stdout, exit, warning markers) and `e*` (rejection messages) |
| lifetime | checked no-GC default, temporary loops/functions, recursive scratch, allocating conditions, callbacks, escaping values, explicit opt-in and large regions under a 64 MiB cap |
| native-examples | every `test/y/examples/*.y` the built compiler accepts prints what the reference prints |
| examples, audit, loops, comprehensive | the regression corpora and the inline edge cases |
| ycc-units, ycc | `test/y/ycc/*`; one-liners, warnings, driver failures |
| fixpoint | three self-compiles byte-identical; `src/y` and `src/y/std` warning-free |
| debug, link, pkg | `-g` output; the std pack; `ycc build`/`vendor` over real projects |
| pack | `ycc --pack`: a packed program runs like the plain one (stdout, exit, argv, environment); every method decodes; `cycc` and `ycc` pack ordinary programs byte-identically; each packs a compiler that compiles the same bytes from an empty directory (the seed can retain a compressed std pack); the refused flag combinations; the packed-size ratchet (`test/pack/sizes.txt`) |
| stdin-eof, net | stdin/EOF; loopback HTTP/TCP, DNS and TLS |
| gui | `std/gui` against an X server (`$GUI_DISPLAY`, else Xvfb, else weston + Xwayland started for the run): present is what the server holds, a resize is an event, xdotool's typing, click and wheel and python-xlib's WM_DELETE_WINDOW come back as events (`test/gui/`). The headless window is `native/t435`, the Win32 one `test/pe/guiwin.y` (`pe-fixtures`) |
| lsp | the server's fixtures under both compilers, `ytest check-refs`, `ytest check-names`, formatter idempotence |
| math | `test/math/ulp_table.txt` within 1 ulp, every answer in it correctly rounded (`ytest math-table`, against `mref.y`'s 320-bit references), the kernel tables the fit (`math-fit`), the assembly kernels what their generators write (`math-gen`), plus the threshold and repetition audits |
| coverage | every diagnostic and manual section has a checked test (`test/COVERAGE.md`) |
| obf | `--ob`: the one full level runs like the plain build; same seed is byte-identical, different seeds differ; the marker and fixed magic are absent from the file; a flipped image byte is refused; the key path is not plaintext; `--ob-map` is outside the binary; gdb cannot start a full build; threads and fork survive the lazy loader (t907/t908); the bytecode call bridge handles recursion and four stack arguments (t909); two calls in one expression drop their argument windows from the virtual stack (t911); setcc/movzbq stay in bytecode (t910); SSE arithmetic, float compares and integer division stay in bytecode (t912); a literal longer than two pages reads correctly through the lazy pages (t913); a sealed PE runs on the Windows machine (`test/pe/obfseal.y`, `pe-fixtures`); the bytecode is per-function xored; bytecode helpers match the plain build and `cycc`; the refusal matrix; `--ob-report` (`src/tools/ytest/su_obf.y`) |
| web-smoke | the web target under Node: `--target=web` writes a site `src/web/yhost.js` validates, `--emit=wasm` writes a module, `test/web/w001_hello` runs, argv and the environment cross the host boundary (`w002_args_env`), `exit(7)` is status 7, every refused flag, `--emit=wat`, the site, `--web=stack`, the host selftest, `web-forms`/`web-census`/`web-abi`, the `test/web` fixtures and cycc/ycc byte parity (`src/tools/ytest/su_web.y`) |
| web | the whole `test/y/native` corpus through `src/web/yhost.js --fuel=200000`, with `NAME.expected.web`/`NAME.skip.web` and the `test/web` fixtures (threads, sleep order, flags, NaN, division, tokens, big bodies, traps, checked, stdin, gui present/keys/resize/grid on the virtual display through `w020`–`w023`, and `snd` into the Node WAV sink through `w030`/`w031`); skips are fork, sockets, exec and obf, each with its reason; the compiler compiled for web recompiles `hello.y` to the native ELF byte for byte (`src/tools/ytest/su_web.y`) |
| web-browser (by hand) | the page in headless Chromium/Firefox: `?ytest=1` `YDONE`, console/stdin/stderr, IndexedDB persistence, `pause_hidden`, `start=click`, `files.bin` under `/app`, the feature check; the canvas and input (`w110`–`w112`: checksum vs `read_back`, opaque pixels, channels, zoom/fit, the native X11 key golden, preventDefault/context menu, fit `EV_RESIZE`); the audio (`w112_audio`: AudioContext running, consumed frames, non-silent page audio, the gesture hook, mute); the page API (`w113_fetch`: a sibling file through the page's fetch, a 404, `param`, `eval`, `open_url`); the default site and `--web=single=true`, `ycc build --target=web`'s site, launcher, `files.bin` and single file; the Node host/gui unit tests (`src/tools/ytest/su_webb.y`, `src/web/test/browser.test.mjs`; `make web-browser`) |
| gc | explicit collection under a cap: two threads of 300k allocations must run in 64 MiB (`test/y/native/t385_gc_threads_alloc.y`), checked `--gc=never` rejects that workload, and two threads of 20k run under `--gc=stress` (a cycle at every allocation, `test/y/native/t389_gc_stress_threads.y`) |
| kernel | `test/kernel/`: each fixture built with both engines (`--target=kernel`), images compared, booted under qemu, serial output and exit status checked (`src/tools/ytest/su_kernel.y`; needs `qemu-system-x86_64`) |
| os | `test/os/`: Y-OS (`make os`) built by both compilers (identical images), then scripted shell sessions booted under qemu and compared with their transcripts (`src/tools/ytest/yos.y`, `ytest os-session`); a session with a sibling `NAME.wav` also asserts the recorded audio is not silent. The kernel modules are `os/kernel/*.y` (yunix: directories, pipes, threads, tty, AC97, AF_UNIX;) |
| treeshake, std-suites | the unused-code cost ratchets, plus four checks a runtime addition must pass: a program that allocates nothing names no `y_alloc` and no collector block, `--gc=auto` omits the collector for a one-shot allocation while `always` keeps and `never` drops it (same output), `ytest deadcode` counts instructions the shake leaves unreachable (`test/treeshake/deadcode.txt`), and `test/treeshake/shapes.txt` records the size of the shapes a runtime change moves first; the `test/std/` self-test suites |

Run by hand (not in `make test`): the Windows gates above (`make pe-test`,
`make pe-cycc`), `ytest w-sysno`, `ytest run-parity` (`ycc run` == compile + execute),
`ytest mem`, `ytest gcov`, `make lsp-e2e`, the math sweeps (`ytest math-exact`,
`math-float`, `math-edges`), `ytest oom`, `ytest install-vscode`, and
`make web-browser` (headless Chromium/Firefox; needs a browser, not part of `all`).

Fuzzing (`ytest fuzz [ITER] [SEED]`): mutates corpus programs and compiles
each with both compilers under the cap and a timeout; a crash or a divergence is
saved with its input. Run it after touching the lexer, parser, checker or
emitter, and turn each finding into a `test/y/native/e*.y` fixture. Malformed
input gets an error at the offending token — never a crash, never silent
acceptance.

`ytest fuzz --data [ITER] [SEED]` does the same for data: it mutates seed inputs
(`test/data/*/fixtures.bin` and the encoders' output) of the std decoders that parse
outside bytes (`audio`, `img`, `zlib`, `json`, `regex`, `utf8`; `test/fuzz/data.y`)
by truncation, bit flips, random bytes and length fields set to 0, 1, 0x7fffffff and
0xffffffff, and saves any trap, timeout or cap hit with its input under `_check/fuzz`.
Turn each finding into a hostile-input case in the decoder's `t*` fixture. A short run
(500 inputs per decoder) is in `std-suites`.

## Pipeline

Splice imports, pick the std units → per unit: strip namespaces (`strip_ns`,
`strip_type`) → rename → typecheck → escape (escape.y: region errors, region
summaries, automatic regions) → lint (warnings to stderr; the program's unit
and its packages, never a std unit) → hoist → emit bodies → link and tree-shake
the units into one `.s` → `asm.y` assembles → `elf.y` writes the ELF (`-g`:
`dwarf.y`'s line table). `y_` is a **reserved prefix**: such a def is emitted
under its bare name because generated code calls it by label, and a program's own
`y_` def replaces the std one at link time.

## Y code style (hard rules)

- An **empty block is legal** and void — `{ }`, no `0;` filler. A block's value
  is its last statement **without** a `;`: `{ f() }` is `f`'s value, `{ f(); }` is
  void. `if` arms need not agree: disagreeing arms make the `if` void.
- Postfix binds tighter than unary: `!x.y` is `!(x.y)`, `x.y[i]` is `(x.y)[i]`.
  `&&`/`||` short-circuit and take any non-zero value as true.
- Recursion is `self`, never the function's own name.
- `#{ … }#` is a **meta block**: compiled and *run* at compile time, its output
  spliced in its place. Top level only; the generator runs in a forked child, so
  a trap in a block is a diagnostic rather than a dead compiler. In a file with a
  block, a top-level statement must be a declaration.
- `ndef f(params) -> T [= "label"];` declares a bodyless def implemented by an
  assembly label (`y_` prefix, top level, return type written).
- A nested `def` captures the bindings already in scope where it is written;
  captures are shared with the enclosing scope. The generated bootstrap supports
  closures. Top-level variables are globals, never captures.
- Arrays, maps and records are **references**; strings and numbers are immutable
  (`s += t` may append in place only into a buffer nothing else can see).
- Arrays are **homogeneous**. Records are **exact**: a record type is its fields,
  and a record goes only where its own type — or a union holding it — is expected.
- **No unknown types**: every parameter is annotated or has a literal default;
  `[]`/`none` take their type from the annotation or the context; a forward-called
  def has its return type written. A union field other than the shared ones is
  read after a cast (`let c: Call = node;`, or a `match` binding); a cast copies
  when the layouts differ, so never write through one expecting the union to
  change.
- **No warnings** in `src/y` or `src/y/std` (`src/tools/ytest/su_fixpoint.y`). An unused
  parameter is fine, an unused local is not. A record or union type used in more
  than one place gets a `type` alias in the module that owns it.
- `/** … */` is a **doc comment**: the scanner marks it and the server shows the
  comment above a declaration in hover. Keep it short, and keep `//` shorter.

## Arrays and pointers

- `a + b` → a NEW array (the operands untouched). `arr + elem` / `elem + arr` → a
  new array with one element. `arr += v` → in place: an array of `arr`'s element
  type appends wholesale, anything else pushes one element. `arr *= v` → prepends
  one element, in place. `a = b` → both names alias one array.
- `arr.length` (also `str.length`) is `len(arr)`; `arr.ptr` is a `*T` to the first
  element (arrays only — string bytes may live in `.rodata`).
- `s.m(args)` on a `str` is a string method: one table, `str_method` in `types.y`,
  feeds the checker and the emitter. Method names are not reserved words.
- `const x = v` fixes the value as well as the binding: every store through a
  place, `op=`, `++`/`--` and in-place `+=`/`*=` on a const array are type errors.
  A pointer still launders it (`&a[0]`, `*p = 1`) — the checker does not follow.
- A **fixed** `[T; N]` cannot grow: `+=`/`*=` on it is a type error.
- `x++`, `++x`, `x--`, `--x` and `x op= e` evaluate the target's subexpressions
  exactly once.
- `& | ^ ~ << >> >>>` take integers and bind tighter than comparisons
  (`x & 1 == 0` is `(x & 1) == 0`). `>>` is arithmetic, `>>>` logical; a count of
  64 or more shifts every bit out, a negative count traps.
- **Sized integers and packed records** (`K.tint`, `K.tpack`): `i8 i16 u16 i32 u32 u64` and the
  `be`/`le` forms are types only behind a pointer (`*u32`) or inside `packed { .. }`; `*p` is a long,
  a store truncates. `packed { f: T, .. }` (fields in order, no padding) and `bits u8 { a, b, n: 3 }`
  (one bit per bare name, from the low end) describe raw memory: a value is the ADDRESS of its bytes,
  `h.f` is a typed load/store at a constant offset (`gen_pack_load`/`gen_pack_store` over
  `gen_ptr_load`/`gen_ptr_store`), `sizeof(T)`/`offsetof(T, f)` are constants. rename inlines aliases,
  so a packed type is structural; no str/array/map/record field (the collector does not read raw memory).
- Pointers: `&x`, `*p`, `p + n` / `n + p`, and `p - q` for identical pointer
  types. Only `+=`/`-=` take offsets (`*p *= n` is an error), and `*long + *long`
  is not an expression.

## Layout

- `src/y/` — the compiler: `ycc.y` (driver), `pkg.y` (`ycc build`), `lexer.y`,
  `parser.y`, `rename.y`, `types.y` (checker), `escape.y` (what may outlive a
  region; automatic regions), `lint.y` (warnings and `--warnings=fix`),
  `native.y` (emitter), `meta.y`, `ir.y` (the instruction IR), `labels.y`,
  `arch_x64.y`, `enc64.y`, `asm.y`, `elf.y`, `pe.y` (the PE writer), `kelf.y`
  (the kernel image), `dwarf.y`, `target.y`, `tags.y`, `packstub.y` (the
  `--pack` stub); `std/` (the four core units, plus
  `fs`, `net`, `struct`, `math`, `crypto`, `x509`, `tls`, `regex`, `json`,
  `args`, `tui`, `utf8`, … — all of them pack units, see Build); `arch/*.s`.
- `src/c/` — the boxed value runtime for `bootstrap/ycc.c`.
  `PORTING.md` describes seed generation and verification.
- `src/tools/lsp/` — `yserve` and its modules (`LSP.md` is the design; the VS Code
  extension is under `vscode-y-lang/`) with `test/` (fixtures, harnesses, node
  drivers, and two measurement programs, `scope-coverage.y` and
  `request-cost.y`). Syntax highlighting is the **TextMate grammar** the extension
  ships; the server does diagnostics, hover, definition, completion and
  formatting. `ytest check-names` also tests each module's basename, because
  `strip_ns` rewrites any `name.field` program-wide as a module reference.
  `src/y/.ycontext` makes editor analysis of compiler modules use `ycc.y` as the
  entry point, with the open document's unsaved text overlaid during resolution.
- `os/` — Y-OS: the kernel modules (`os/kernel`), the shell and its programs
  (`os/uland`), `mkfs`, and `os/manifest.txt` (what goes into the image). The
  manual's "Y-OS and yunix" chapter describes it.
- `src/tools/ytest/` — `ytest`: the test framework, every suite, and the tools
  (`./ytest help`).
- `src/web/` — the JavaScript host for `--target=web` (Node and the browser);
  the manual's web chapter and `docs/TARGETS.md` describe it.
- `examples/` — larger programs written in Y (games, a ray tracer, an editor,
  an HTTP server, an X11 client); Y-OS ships them in `/bin`.
- `refs/` — reference binaries for the port gate. `test/` — `sh/capped.sh`, `y/`
  fixtures (`native/`, `audit/`, `examples/`, `ycc/`, `net/`), `std/`, `math/`,
  `kernel/`, `os/`, `pack/`, `pe/`, `treeshake/`, `data/`, `fuzz/` and
  `COVERAGE.md`. `bench/` — benchmarks and the compare/profile
  scripts. `docs/` — the manual (`make docs`) and `TARGETS.md` (target ABIs).

## Native backend

Unboxed 8-byte values (`long`/`int`/`byte`/`bool`/`float`/`ptr`/`str`/option/
function); `[byte]` arrays are packed. Stable heap headers `{len, cap, data,
front}` with capacity doubling at the back for `+=` and room reserved in front for
`*=`, so both are amortized O(1); `s += t` on an owned `str` likewise. Closures
are `[code, caps…]` records; records are laid out by field name (a union member:
the shared fields first) with a pointer to their type descriptor before the
fields. `for`/`for..in`/`foreach`/`while` with `break`/`continue` (a jump out of a
`def` nested in a loop is refused by the checker); block expressions; `type`
aliases, record unions and `match`. Threads (`spawn`/`join`, `mutex`/`lock`,
`sem`) are `clone(2)`s with a heap of their own; processes are `fork`/`wait_pid`;
every exit is `exit_group`. `ycc` is native-only — no cc/as/ld at run time — and
the shipped binary is a static ELF carrying its std pack.
