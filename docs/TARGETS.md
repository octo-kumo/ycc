# Target descriptions and encoder generation

The compiler supports Linux x86-64 (`--target=linux`, the default), Linux
AArch64 (`--target=linux --arch=aarch64`), Windows x86-64 (`--target=win`) and the
freestanding x86-64 kernel target (`--target=kernel`).

`src/y/target_schema.y` describes the platform's object format, runtime source
blocks, thread runtime and syscall ABI. `target_shapes.y` expands it into
descriptors consumed by the driver, emitter and runtime selection. Changing an
ABI's register list also changes its register-argument count. The Windows
stack area and first stack-argument offset are recorded beside that list.

`src/y/x64_schema.y` describes instruction aliases, operand counts and encoder
expressions. `backend_codegen.y` generates both the assembly-text dispatcher
and the direct IR dispatcher. `encoder_shapes.y` joins those recipes with
`ir_schema.y`, so adding an IR form automatically selects its mnemonic's
encoder. Special operand-dependent encodings remain ordinary functions in
`enc64.y`; both dispatchers call them.

`ir_schema.y` also describes operand fields: numeric words and label identities.
Meta derives each form's wire layout alongside its constants and operand list.
Packing, decoding and both reference scans consume that layout;
new forms inherit their serialization from their operands. Operand order fixes
operand IDs, just as form order fixes form IDs. An instruction has at most seven
operand fields; the generator rejects unknown operands and oversized forms.
`REG`/`IND` carry a register number and size. `MEM`/`MEM0` carry base, index,
scale, displacement and label (-1 when absent); `MEM0` omits textual displacement.

A new platform requires a descriptor, its runtime assembly blocks and an object
writer if it uses a new format. Platform-specific startup, syscall instructions
and foreign-call conventions still need implementation. The schema supplies
policy; it does not invent an ABI implementation.

The AArch64 backend lowers the shared instruction IR in `enc_a64.y`. Packed
units retain their existing register identities, value layouts and Y calling
convention, so the same precompiled std pack works for both architectures.
`TARGET_ARCH` describes these shared IR registers; `arch_id()` names the actual
output architecture and OS. The x86 encoder and its generated dispatchers are
unchanged. AArch64 uses fixed-width instructions, checked branch relocations
and full-width address materialization; the ELF writer selects EM_AARCH64 and
64 KiB segment alignment for both 4 KiB and 64 KiB Linux kernels. `-g` includes
symbols and source lines. `--emit=asm` emits AArch64 `.inst` directives with symbolic
branches and address relocations, which Clang's AArch64 assembler also accepts.

The Y stack uses x28 and eight-byte slots. Calls explicitly push return
addresses, preserving existing packed closure and argument layouts. x16–x27
and x30 are lowering scratch registers, and x29 holds the Y frame pointer.
At a Linux syscall boundary SP is aligned below the live Y stack; x0–x5 hold
arguments and x8 holds the syscall number. The runtime translates its shared
Linux syscall identities and adapts stat layout, open flags, poll timeouts,
fork/clone, pipe/dup and thread-local storage. Raw syscalls reuse the collector
parking protocol, including dynamically selected syscall numbers. Thread startup copies the saved
registers onto the child stack; exiting threads unmap their stack without
subsequently reading it. Atomic exchange uses acquire/release exclusives and
memory barriers. Floating point lowering preserves the runtime's NaN and
float-to-integer conventions.

A user's `syscall()` takes **AArch64 Linux numbers** on this target (write 64,
openat 56, close 57). Standard library calls remain portable. Both Linux architectures support all
four `--pack` codecs and static, seal and full obfuscation, including the
bytecode VM, external keys and key descriptors. Pack stubs use their own
host syscall ABI; an existing ELF selects the matching stub automatically.
Built compilers carry both stubs, so cross-packing works without source files.
The outer `YCCSTUB1` frame is unchanged; its body is now
`"YCCSTB2!" || X86_LEN8 || x86_stub || aarch64_stub`. Older single-stub frames
remain readable for their matching architecture.

Sealing keeps the cipher's 4 KiB logical pages and uses 64 KiB protection
pages on AArch64. The loader synchronizes instruction caches before execution.
Lazy faults enter on the kernel's signal stack, remap the native argument
registers and return through AArch64 `rt_sigreturn`. During sealed execution
SP stays aligned below the live Y stack, including between syscalls, so signal
frames cannot overwrite it. The shared loader and bytecode interpreter are
lowered through the same backend as ordinary code.

`make ycc-aarch64` builds a self-contained compiler for AArch64 Linux. Copy it
to an ARM machine and run it directly; its default target is AArch64.
`--target=linux` cross-compiles back to x86-64. Compiler host calls and meta
execution follow the running executable independently of its output target.
No external cross toolchain is needed. Windows ARM64 and a freestanding
AArch64 kernel remain outside this target's scope.

`make aarch64-test` (or `YCC=$PWD/ynew ./ytest -j4 aarch64`) compiles the native
corpus and runs it through `qemu-aarch64`. `QEMU_AARCH64` overrides the emulator.
The suite checks both target flag spellings, ELF headers, debug builds, an
independently assembled listing, C/Y image parity, native syscalls and a blocked
raw reader during collection, plus existing expected output,
exit status and warning markers. Fixtures with hard-coded x86 syscall numbers
carry `.skip.aarch64` explanations. The suite also checks every pack codec,
argv/environment/exit preservation, both hosted cross-compilation directions,
source-free std and stub lookup, meta execution, two byte-identical ARM
self-compiles, and concurrent lazy faults across many pages. Hosted meta and
packing tests under qemu-user need the AArch64 binfmt_misc handler so child
executables can run. Seal tests disable anti-debug under QEMU because it does
not implement `ptrace`; full mode still exercises its default dumpable guard.
Execution checks are skipped when QEMU is absent; header and driver checks
still run.

Keep serialized form IDs stable. Run the self-compilation gate and corpus
comparison after changing encodings. Windows execution checks run on the real
machine configured by `.pe-vm.conf`, through `make pe-test`.

## Web (`--target=web`)

`web` is a wasm32 target: linear memory is 32-bit, values are 64-bit, and the
only imports are `y.sys` (the Linux syscall table, number first) and `y.trap`
(a signal number). The object writer is `src/y/wasm_link.y` + `wasm_lower.y`;
the runtime blocks are `src/y/arch/prelude.s` with six replacements from
`src/y/arch/web.s` (the audio and host-call entries).

The shared IR is lowered into **chunks**: a chunk is a wasm function with one
entry case per label, a `br_table` dispatcher and a loop; every transfer is a
`return_call` (or `return_call_indirect` for a token), so Y's stack grows in
linear memory, not in the engine's. A code address is a token
`2^40 + (chunk << 20) + case`; it can never be a wasm32 pointer. The register
file and flags live in wasm globals, copied through a 512-byte context by
`ctx_save`/`ctx_load`; the host schedules green threads at syscalls and fuel
points and reads the yield reason from `why()`. `set_why` is the host's way to
set that reason before `resume`.

The module exports `memory`, `resume(i64)`, `ctx_save(i32)`, `ctx_load(i32)`,
`set_fuel(i32)`, `why() -> i32` and `set_why(i32)`. The `yweb` custom section
carries `abi`, `stack_lo`, `stack_hi`, `data_lo`, `data_end`, `heap_lo`,
`entry`, `chunks`, `threads`, `gui` and `audio`. The host refuses an unknown
`abi`. The initial stack is the Linux one (argc, argv, envp, auxv), and the initial `rsp` is context slot r4.

Private syscall numbers; they start at 22784:

| nr | name | args | result |
|---|---|---|---|
| 22785 | `HOST_SYM` | `name_ptr, len` | handle > 0, or 0 |
| 22786 | `HOST_CALL` | `handle, args_ptr, n` | the function's result (may block) |
| 22787 | `AUDIO_DEVS` | — | 1 or 0 |
| 22788 | `AUDIO_OPEN` | `rate, channels` | handle > 0, or −errno |
| 22789 | `AUDIO_WRITE` | `h, ptr, len` | `len`, or −errno (may block) |
| 22790 | `AUDIO_CLOSE` | `h` | 0 |

Every other number is the Linux x86-64 syscall table, answered by the
JavaScript host (S9). Statuses are `exit_group(n) & 255`, `128 + signal` for a
trap (SIGILL 132, SIGTRAP 133, SIGFPE 136, SIGSEGV 139), 139 for any other wasm
trap, and 134 for a host bug.

Sound uses the four private audio numbers: the Node host records the
interleaved 16-bit samples to a WAV with `--audio=FILE.wav` (nothing blocks),
and the browser host plays them through an inline `AudioWorklet` (a
`ScriptProcessorNode` fallback when a CSP refuses the Blob URL); a browser
`write` blocks the green thread while more than 250 ms is queued, and the first
pointer or key gesture resumes the context and drops backlog beyond 100 ms.

The std pack carries `gui@web` beside the base units: `src/y/std/gui.y` merged
with `src/y/std/gui.web.y` (S14's target overlay), compiled for web and linked
as `gui` when the compile's target is web. Other targets link the base `gui`.
The overlay resolves the nine `gui.*` host functions through `y_os_host_sym`/
`y_os_host_call` (S11) and keeps the X11/Win32 arms for native builds.

`std/web` (S10) is the page's own API, one pack unit appended after `gui`:
`available`, `platform`, `sym`, `call`, `call_str`, `eval`, `log`, `param`,
`open_url` and `fetch`. Off the web every one of them answers "not available"
(false, "", 0, none) because `y_os_host_sym` answers 0, so a program that
imports it compiles for Linux, Windows and the kernel unchanged. A host
function that answers a string takes `(buf, cap)` as its last two arguments
and returns the length, or `-(needed)` when it did not fit; `call_str` retries
once with that size. A small negative is an error and becomes none, which is
how `param` says "no such parameter" (-ENOENT) and `eval` says "it threw"
(-EIO). `log` is one line: the page writes it with `console.log`, the Node
host appends one newline to the program's own stdout so the output keeps its
order with `puts`. `fetch` answers a handle into the host's table, `fetch_len`
its length, `fetch_read` copies it into `(buf, cap)` and `fetch_free` releases
it; the host's promise blocks the calling green thread. The Node host is platform
"node" (no query string, `vm.runInThisContext` then a function body for eval,
a `file:` URL or a path relative to the working directory read from disk,
otherwise Node's fetch, and `open_url` false); the page is "browser" (`param`
from `location.search`, eval as an expression then a function body, `fetch`
with a non-2xx status or a network error as none, `open_url` a `window.open`).
A page may register its own `app.*` functions and reach them through
`sym`/`call`/`call_str`.

Any change to these numbers, the import/export signatures, the context layout,
the token encoding or a host function's arguments bumps `abi` here, in
`src/web/abi.js` and in the `yweb` section together; `ytest web-abi` checks
that the three agree.

## The web page

The page provides the stage the application runs in: one full-window area. A
program that opens a gui window draws into the viewport; a program without one
gets the console (the page's stdin/stdout/stderr). `[web] console = "show"`
adds the console over a window; `"hide"` keeps it closed; `"auto"` follows the
program.

The site writer inlines `page.css` and the page's linked host modules into
`index.html`, so `ycc --target=web --web-page DIR` writes `index.html`,
`NAME.wasm` and (when `[web] files` is set) `files.bin`. `--web-page=html`
inlines the module and the bundle as data URLs and writes one file. The
`[web] zoom` default is `"1"` (100%); `"auto"` is still the largest integer
that fits in fixed mode. A `[web] template` page keeps the four placeholders
`TITLE`, `CONFIG`, `HOST` and `MODULE`.

`ycc build --target=web` writes the same site under `build/web/NAME/`, a
single file under `build/web/NAME.html` when `single = "true"`, and a Node
launcher under `build/web/bin/NAME`. The launcher keeps its host in
`build/web/bin/host/`.
