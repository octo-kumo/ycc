# Branch integration status — `math-portable` and `meta-win`

This records the state of the two long-lived branches after both were merged
into `master`, what was still open at each tip, and what this integration pass
finished. It is the "done / doing / yet to do" ledger for the two branches.

Last updated by the integration pass that merged them (see *The merge* below).

---

## TL;DR

- **Both branches are in `master`.** `math-portable` merged cleanly;
  `meta-win` conflicted in five files that were resolved by hand.
- **The tree builds and is self-consistent**: `./cycc` (the C copy) compiles
  `src/y/ycc.y` to the same bytes as the Y compiler's own self-compile, and
  three generations fixpoint.
- **Every suite passes** (run with a fresh `/tmp`; see *Environment* at the
  bottom for the one trap).
- **Finished in this pass:** the math branch's pending IR reductions, the
  encoder guard the Windows design claimed but never had, the two stale
  comments that promised things nobody had built, W1's `cycc.exe` (mingw-w64,
  all but the meta fixtures byte-identical), a child's stdio in `std/exec.y`,
  `ycc run FILE -- ARG...`, and a Y test/metrics runner with gcov line
  coverage (`./ytest`).
- **Still open:** the Windows work that needs NT implementations — the rest of
  the named-syscall layer (`B2`), the PE syscall self-test, NT `fork`/threads,
  BCrypt crypto, console `readline`, and `W6`'s harness. `W1` is done as far as
  the corpus can take it (mingw-w64 + wine are now installed): every fixture but
  the meta ones compiles byte-identically under `cycc.exe`. See §3.

---

## 1. The merge

| merged | commits ahead of `master` | conflicts |
|---|---|---|
| `origin/math-portable` (`87edd89`) | 65 | none |
| `origin/meta-win` (`1c2d0f9`) | 44 | `src/y/native.y`, `src/c/native.c`, three LSP `.expected` files |

`math-portable` was already up to date with `master` (`00dd221` plus the two
commits `master` had since), so its merge was clean. `meta-win` was based
further back and both branches touched the lexer, the emitter, the checker, the
assembler and the driver, so the merge needed real resolutions:

- **`src/y/native.y` / `src/c/native.c`** — math renamed the string-to-number
  builtin (`tonum` → `tolong`, plus `tofloat`) in the inferred-type and
  `INTRINSICS` lists; meta-win added `os_call` and `jmp_at`. Both sides are
  kept, name-for-name and in order, in both copies.
- **`src/c/meta.c` / `src/y/meta.y`** — the meta pass arrived on `meta-win`
  after the rename and still called `tonum`. Both copies now call `tolong`
  (this was the only stale `tonum` left in the tree).
- **`src/tools/lsp/test/t013_m4.expected`, `t014_strm.expected`,
  `t020_sorttext.expected`** — the completion list is enumerated from
  `INTRINSICS`, so the merged list (`tolong`, `tofloat`, `os_call`, `jmp_at`)
  is what the fixtures now expect. Regenerated from the merged compiler's own
  output; the diffs are exactly the builtin list and `44 → 46` typable names.
  (`t018_reported.expected` and `t020_sorttext.expected` were then regenerated
  once more when the math helpers below added three `std/math.y` names,
  `193 → 196` items.)
- **`t020_sorttext.y` is now self-contained.** Its buffer imports
  `./helper.y`, and completion on `helper.` makes the resolver read that file
  from disk; the file used to exist under `/tmp/opencode/t020ws` only because
  someone had created it by hand, so the fixture passed on the machine where it
  already did and failed on a fresh one. It now writes the file itself, as
  `t021_ownlines.y` already did.

**`refs/ycc.ref` was not present in this checkout** (it is gitignored, and the
one in the other worktrees is for a different base). The merged tree was
therefore blessed as the new reference — `make ynew` builds it from source,
`make port-check` shows `cycc` and `ynew` agree on every fixture, `make ycc`
reports `cycc output == refs/ycc.ref == ycc self-compile (byte-identical)`, and
`refs/ycc.ref` is now sha256 `042c0c7a15131288…` (it has moved three times
since the merge — `d7b7c8fe1b296a29…` at the merge, `9ef011d4a1c10080…` after
the `pe_no_abs` guard, `35ba76615fc38845…` after W1/popen, and this one after
`ycc run --`).

---

## 2. `math-portable` — done / doing / yet to do

**The branch's objective:** every `std/math.y` function verified correct, the
`tonum` split into `tolong`/`tofloat`, the ≤1 ulp promise gated, and the IR of
the runtime kernels reduced and measured.

### Done

- **Correctness gates.** The ulp table (8,404 cases) plus `audit_pairs.py`
  (20,000 independent-decade pairs for `hypot`/`atan2`), `audit_thresholds.py`
  (every parameter seam within 1 ulp), `audit_coverage.py` (every def
  reachable), `find_repeats.py` (the repeated-computation ratchet),
  `gen_split_unroll.py --verify`, and `t328_split_unrolled.y` (32,024
  bit-identical questions against `poly_split`).
- **Defects found and fixed:** `hypot` answering `+inf` for a whole decade and
  its 2-ulp wide-ratio error; `atan2` dropping the sign of `y` at an infinite
  `x` and for the four signed-zero pairs; `sinh` returning `+inf` for a
  negative argument past the overflow bound (in the module *and* in the
  reference); `log10`'s compensated `log10_2_lo` term; `rotl` on a count of 65;
  `log1p`'s subnormal; the three bulk-kernel overflow paths; `random.below`
  hanging; and the `0e999999` float literal.
- **`tonum` → `tolong` / `tofloat`**, with every reference in the tree, the
  docs and the diagnostics updated.
- **Kernel unrolling** of `poly_exp`, `poly_log`, `poly_sinh`, `poly_tanh`
  (were loops) and `poly_atan`, `poly_asin`, `poly_sin`, `poly_cos`
  (~2× fewer instructions per call), all generated and gated by
  `t328_split_unrolled.y` and `gen_split_unroll.py --verify`.

### Finished in this pass (the branch's own "Next Steps", IR Reduction)

All four are bit-identical by construction and were verified bit-for-bit with a
probe compiled against the old and the new `std/math.y` (1,589 lines of IEEE-754
bit patterns, `cmp` clean):

| change | what it removes |
|---|---|
| `prod_err` split into `split_hi`/`split_lo`/`prod_err_s` | the repeated Dekker split of an operand |
| `cbrt`'s residual | `y` was split 3× and `y2` 2×; now once each |
| `rem_pio2`'s error term | the same `nf` split was computed twice |
| `asin_half`'s `2*s` | bound once instead of three times |
| `fvariance`'s `len(a)` | bound once (`find_repeats.py`'s own KNOWN entry, now retired) |

The `find_repeats.py` ratchet now carries only the documented `atan`
branch-disjointness false positive.

- **The PE now has an import table**, which is the prerequisite for three of
  the Windows items at once: Windows has no syscall for randomness
  (`BCryptGenRandom`), for sockets (Winsock) or for the console API, so BCrypt,
  `std/net` and console `readline` all arrive as **DLL imports** and the writer
  had none. `pe.y` emits a well-formed `IMAGE_IMPORT_DESCRIPTOR` for
  `KERNEL32.dll!GetCurrentProcessId` -- ILT, IAT, hint/name entries and the DLL
  name in a writable `.idata`, every pointer an RVA so the image stays
  RELOCS_STRIPPED -- and the loader resolves it at load. `objdump -p` reads it
  (`DLL Name: KERNEL32.dll` / `Member-Name: GetCurrentProcessId`), the PE still
  runs under wine, and `pe-gate.sh` now asserts both, because nothing else
  looked at an import at all.
  The table now carries **two** DLLs -- `KERNEL32.dll!GetCurrentProcessId` and
  `bcrypt.dll!BCryptGenRandom` -- because one DLL would not have exercised the
  descriptor chain, the per-DLL ILT/IAT offsets or the name table, and because
  the second is exactly what the BCrypt body needs. `pe-gate.sh` asserts both
  by name.
  **The import list now lives in `arch_x64.y`** (`w_imports`, plus
  `w_iat_label`/`w_iat_term_label`), because two things need it from opposite
  ends of the build: the linker reserves a `.bss` cell per imported function
  and the PE writer emits the table that fills them. One list, or the two
  drift. (Declaring the record type twice is a warning, so `pe.y` uses
  `WImport` directly -- `src/y` must compile without one.)
  **What is left for BCrypt is one piece, and it has to land as one piece**,
  because the cells are inert until something references them:
  **The plumbing is now IN and verified, and the crash that forced round 34's
  revert is fixed.** The difference is where the cells live: they are no longer
  appended to the globals list (where their `.bss` offsets had to be asked of
  the assembler's label map, and came back wrong for a program with std units --
  the fallback left the code pointing at an unfilled cell while the loader wrote
  the resolved addresses somewhere else, which is what a PE dying in its own
  startup self-test looks like). `w_iat_bss_lines()` emits them as the FIRST
  thing in `.bss`, so a cell's offset is arithmetic on the import list
  (`w_iat_offset(d, f)` = 0, 8, 16, ...) and the writer, the assembler and the
  loader agree by construction. Measured: `FirstThunk` equals `.bss`'s RVA for
  both a one-function program and `test/sh/pe-fs.y`, which imports std units and
  now runs correctly under wine. `pe-gate.sh` asserts that equality.
  **The BCrypt body itself is still ENOSYS**, with every finding from the
  attempt recorded in `wsys.s` next to it, and ONE open question:
  `BCryptOpenAlgorithmProvider` returned 0 (success) while the slot it was
  handed stayed unwritten, and the next call faulted on a handle of -1 -- which
  says the call that ran was not the function the label names. So the next step
  is to prove or disprove that the cells and the offsets agree (dump the cell's
  contents, or the address objdump resolves) before rewriting the body.
  Round 34's two observations, for the record:
  * the CALL PATH WORKS: the linker reserved the cells, `asm.y` resolved each
    one's `.bss` offset from its label map, `FirstThunk` became `.bss` + that
    offset (measured 00002030 and 00002040 for a program with no imports of its
    own, with the ILTs and name tables still at 00005000 in `.idata`), and with
    a temporary body calling `y_iat_GetCurrentProcessId` a PE returned the
    process id under wine with no fault -- so the loader fills the cell, the
    `mov ...(%rip), %rax` reads it and `call *%rax` lands.
  * and it is NOT SHIPPABLE AS WRITTEN: for the gate's own program (`pe-fs.y`,
    which imports std units) `FirstThunk` stayed 0000905c -- the copy inside
    `.idata`, i.e. the fallback -- so one of the two paths is wrong for one
    shape of program; and worse, with the cells reserved a PE's W3 startup
    self-test died on `wine: Unimplemented function
    ntdll.NtMapUserPhysicalPagesScatter called at 0000000140001A9B`, which is
    the shape of a wrong syscall number OR of code and data overlapping. The
    self-test is the program's first instruction, so that is a startup crash,
    not a late one: the render was reverted and `pe-gate.sh` is green again.
  **So the next attempt starts by explaining those two observations**, not by
  rewriting the plumbing: where `bss_len` comes from for a program with std
  units (`asm.y` sums the section's items, so the reserved cells should be in
  it), and why the self-test in particular notices. The pieces to re-add are
  the three edits described below, unchanged.
  (1) `native.y`'s link: for a Windows target, `gls += w_iat_label(fn)` for
  every function in `w_imports()` and one `w_iat_term_label(dll)` per DLL --
  the cells then exist in `.bss`, in that order, which is what makes the
  loader's sequential write land in the right slots;
  (2) `asm.y` resolves each label's `.bss` offset from its label map and
  passes the list to `pe_build`; `pe.y` sets `FirstThunk` to `.bss`'s RVA plus
  that offset instead of the in-`.idata` IAT (the ILT, which carries the names,
  stays in `.idata` -- the loader walks it and writes the IAT);
  (3) `wsys.s`'s `y_os_random` becomes `mov y_iat_BCryptGenRandom(%rip), %rax;
  call *%rax` with rcx = `BCRYPT_USE_SYSTEM_PREFERRED_RNG` (2), rdx = buffer,
  r8 = length, r9 = 0, 32 bytes of shadow space and `rsp % 16 == 0` at the
  call -- the load form and `F_CALL_IND` both already exist, used by closures;
  (4) a property fixture (16 bytes, non-zero, two draws differ) whose output is
  deterministic, so it passes on BOTH targets -- `t158_crypto.y` cannot be the
  gate because its own output depends on the random bytes.
  The two functions are still scaffolding: nothing calls them yet, and the
  order is deliberate -- the loader's resolution path is exercised end to end
  *before* a BCrypt body depends on it, so a missing import is a "DLL Name"
  line rather than a mystery.
- **A latent PE bug found while doing that, and fixed**: `pe_build` looked each
  extra section up in the record list it had just built rather than in the
  placed one, so every `.debug_*` section of a `-g` PE was written from file
  offset 0 with `SizeOfRawData` 0 -- `objdump` printed the section and then
  "file truncated". The Y compiler's `-g` PE carries its debug bytes now and
  `pe-gate.sh` checks that too.
- **And one that is still open, C-only**: `./cycc --target=windows -g` traps
  with `runtime error: index out of bounds` while the Y compiler's `-g` PE
  builds fine. It PRE-DATES the work above (checked by stashing the change and
  rebuilding `cycc`), and no gate covers it -- `pe-fixtures.sh` runs the plain
  build and `cycc-win.sh` deliberately does not compare `-g` across hosts, so
  this divergence has been invisible. It is a real port-gate hole: a `-g` PE
  case belongs in `cycc-win.sh` once the C path works.

- **`test/sh/w_sysno.py` -- where a pinned NT syscall number can be CHECKED.**
  `arch_x64.y`'s `w_sysno` numbers are pinned to one ntdll sample and the W3
  self-test is the only thing that verifies them, at runtime, on a PE. This
  reads them out of the ntdll **actually installed** instead: the export's stub
  is `mov %rcx,%r10` then `mov $imm32,%eax` then `syscall`, so the number is
  the immediate at byte 4. Run `python3 test/sh/w_sysno.py NtClose NtCreateFile`
  and it prints the number, the RVA and the raw stub.
  Validated against the pinned table: all ten numbers `w_sysno` carries -- 6, 8,
  15, 24, 30, 44, 49, 52, 80, 90 -- come back exactly, which is the first
  independent confirmation that table has ever had.
  It immediately settled a guess: `NtQueryFullAttributesFile` is **196**, not
  the 62 the public Win10 table suggests (62 is `NtQueryAttributesFile`'s
  neighbour by coincidence, and calling it answers STATUS_INVALID_HANDLE).
- **`y_os_stat` on NT WORKS** (round 38), and it is the first of the eleven
  missing bodies. `fs.exists`, `fs.is_file`, `fs.is_dir`, `path_mode` and
  `file_size` now answer correctly on a PE over paths with separators in them --
  measured against the Linux build of the same program, byte-identical output,
  including `file_size("src/y/std/fs.y")` = 12546 on both. `test/y/native/t349_fs_stat.y`
  is the dual-target fixture (it compares the size instead of printing it, so it
  does not have to change when fs.y does).
  What it took: an ABSOLUTE path built in the body -- `\??\` plus the CWD's own
  DOS path from the PEB (ProcessParameters+56, a UNICODE_STRING whose Length in
  BYTES is at +56 and whose Buffer is at +64), then the relative part widened
  byte by byte with `/` translated to `\`, and an empty path refused rather than
  resolving to the CWD. A relative name answered STATUS_OBJECT_PATH_SYNTAX_BAD
  because the kernel does not do that resolution.
  The number, 196, is in `w_sysno` in BOTH copies with the reason it is not the
  public table's 62 -- and `wselftest.s` now calls it at startup like the other
  ten, so a drift fails loudly in the first instruction of every PE rather than
  in the first file it stats.
- **The path helper is now ONE function, `y_w_path`** (round 39), called by
  `y_os_stat`: `\??\` + the PEB's current directory + the relative part, with
  `/` translated and an empty path refused. Its three arguments are `%rdi`,
  `%rsi` and **`%rcx`** -- not `%rdx`, because every caller is a `replace:`
  block that has just loaded the layer's own argument slots and already holds
  the length there. Passing it in the wrong register assembles, runs, and fails
  as an unwrap of none; that cost a debugging session and is written down in the
  block.
- **`y_os_openat` was written, ran, and did NOT work -- reverted, with the
  exact symptom measured.** `NtCreateFile` (85, confirmed by
  test/sh/w_sysno.py) with the same helper, the same object layout that works
  for `y_os_stat`, access `SYNCHRONIZE|FILE_READ_ATTRIBUTES|FILE_WRITE_DATA`,
  share 7, disposition FILE_OVERWRITE_IF (5) and `FILE_ATTRIBUTE_NORMAL`,
  answers:
    STATUS_OBJECT_NAME_INVALID (0xC0000033) opening an EXISTING file
    STATUS_OBJECT_NAME_NOT_FOUND  (0xC0000034) for a file to be created
    STATUS_OBJECT_PATH_NOT_FOUND  (0xC000003A) for a missing directory
  -- so the path resolution is right (a missing directory is reported as such)
  and something about the call's own parameters is not. `y_os_stat`, called on
  the SAME path, succeeds. Two candidate causes, both cheap to test next, and
  neither yet excluded: the access mask copied into `%rdx` before `%r9` is
  reloaded with `&iosb` (they are arg2 and arg4 and the order matters), and the
  openat frame's object regions sitting ABOVE the path buffer's start, inside
  the range it grows into -- 1900 bytes of headroom for a buffer that can write
  2000, where stat's own layout has exactly 2000. `y_os_close` (NtClose, 15) was
  written the same round and reverted with it, untested, for the same reason:
  it is only reachable through a file handle that openat has to produce first.
- **`readline` WORKS ON NT (round 51).** `std/prelude.y`'s `readline` goes
  through `y_os_read`, which already has a Windows body, and a PE reading two
  piped lines prints what the Linux run prints: `a=hello`, `5`,
  `b=second line`. That closes the goal's "console readline" item for the
  PIPE case. What is NOT tested here is a real interactive console: this
  harness has no tty for wine, so a console handle (as opposed to a pipe) is
  unverified, and `test_std_suites.sh`'s `term_test` needs a pty and only runs
  against ELF.
- **`./ytest` COULD NOT FAIL, and its coverage measured nothing silently
  (round 57).** Two bugs in Y's own test framework, both the same shape as
  things this project has already been bitten by:
    * `ytest.y` ended in a bare `main(argv());` -- a statement whose value is
      discarded -- so the process ALWAYS exited 0. That is verbatim the bug the
      math gate's header documents ("the 1 a failure produced went nowhere, the
      process always exited 0, and the gate could not fail"), and it meant
      `./ytest suites` reporting "0 failed" was a number nothing could act on.
      It is `exit(main(argv()));` now, and the three paths check out: usage 1,
      a missing corpus 1, a valid corpus 0.
    * `./ytest coverage test/y/examples/hello.y` -- a file that is actually
      called `helloworld.y` -- compiled NOTHING and reported "1.3% over 20
      files" as if it were a measurement, because the corpus runs discard the
      compiler's output. A missing path is now named, and a corpus in which
      every path is missing is an error rather than a number.
      And the existence check has to be on the PATH: the corpus entries are
      command strings ending in " -o /tmp/ytest-cov/out", so testing the entry
      for existence rejects every valid path as well. (Tested: it did.)
  The numbers this tool reports were therefore always plausible and never
  actionable. With a real corpus it is 36.3% of the C copy over one example, and
  41.3% over two.
- **`argv()` ON PE IS A NULL FAULT, and the map for fixing it (round 56,
  measured).** `t198_argv_only_length` page-faults on a read of address 0 at
  0x140001328, and `t20_files_argv` fails the same way. `argv()` is
  materialized by the `_start` prologue's `y_argv_init(argc, argv)`, which on
  Linux reads the two values the kernel left on the stack -- and a PE gets no
  such stack. The fixture's own header documents the Linux half of this exact
  bug class ("`y_argv_init` is emitted only when a scan of the AST sees
  `argv()`, and that scan had no arm for a field read, so `argv().length` left
  %r15 untouched and the program died on SIGSEGV"): on PE the register is
  untouched for a different reason and the symptom is identical.
  What a PE prologue has to do instead, so the next round does not re-derive
  it: read the PEB (%gs:0x60), ProcessParameters at +0x20, and the CommandLine
  UNICODE_STRING at +0x70 (Length at +0x70, Buffer at +0x78); split the
  command line into `argc` words and widen/narrow them to the UTF-8 bytes
  `y_argv_init` already expects (ASCII, as everywhere in this layer); build the
  pointer array the same way the Linux path does, set %r15, and then call
  `y_argv_init` unchanged. `t20_files_argv` and `t198_argv_only_length` are the
  two fixtures that check it.
- **THE META FIXTURES WORK ON PE NOW (round 56) -- 7 of the 41 PE-only
  failures were one structural mistake.** A meta block's generator is
  EXECUTED: `meta.y` forks it and runs it in the compiler's own process, and
  the host can only run an ELF. `--target=windows` made that image a PE
  (the emitter AND the linker both read the target), so `elf_img` rejected it
  with "the image is not an ELF file" and every meta fixture died before doing
  anything. The generator is now built with the target set to `"linux"` --
  saved before `emit_program` and restored only after `nasm.ycc_assemble`,
  because both read it -- in both copies.
  The rule this is an instance of: **anything the compiler EXECUTES must be
  built for the host, not for the program's target.** Nothing else in the
  pipeline is in that category (the .text it writes is the program's), which is
  why one save/restore is the whole fix.
  Measured: all six meta fixtures pass on PE (`t197`, `t198`, `t199`, `t200`,
  `t201`, `t202`), so the 41 PE-only failures are 34.
  AND A METHOD NOTE THAT COST A BENCH RUN: `make bench-ir BASE=oldref
  NEW=./cycc` compares the C COMPILER against a Y-BUILT reference -- two
  implementations, not two revisions of one -- and reports +2038% on hello.y
  and +95.77% on ycc.y. Those numbers are not wrong, they are answering a
  different question. `NEW` must be `./ycc`, the Y binary the new compiler
  built; with that, this change is +0.00% on both, as a fix that touches only
  the meta path should be.
- **THE PE-FIXTURE HARNESS COULD NOT FINISH, and now it can (round 55).**
  `test/sh/pe-fixtures.sh` had NO TIMEOUT ON EITHER RUN -- not on the ELF side
  and not on the wine one -- so a single fixture that hangs wedged the whole
  run. That is what the round-54 attempt was: still going after 40 minutes with
  an empty table and no symptom but silence. Every run is wrapped in `timeout`
  now (`YTIMEOUT`, `YTIMEOUT_PE`, both scaled by `YTIMEOUT_SCALE` as in lib.sh),
  a timeout is reported as a result (`... no exit within 20s (HUNG)`), and each
  failure prints as it happens instead of at the end. THE FIRST THING IT CAUGHT
  IS `t199_std_tui`, WHICH HANGS: that one fixture is what made the whole
  corpus unmeasurable.
  **The measurement, at last: 236 fixtures -- 190 PASS both targets, 41 PE-only
  failures, 5 baseline failures.** The 41 cluster into work, not noise:
    * the META fixtures (7: t197-t202 and friends) fail with "cannot run the
      meta generator: the image is not an ELF file". That is structural: a meta
      block's generator is EXECUTED (meta.y forks and runs it), the host can
      only run an ELF, and `--target=windows` makes the generated image a PE.
      Fixing it means building the meta child for the HOST target whatever the
      program's target is -- bounded, and worth more than it looks, because
      every meta fixture is unmeasurable on PE until then.
    * threads (4: t341-t344) -- the `%fs`/clone/futex runtime, mapped below.
    * net (5), exec (3), fork (2), crypto (3), and a long tail of fs/std ones.
    * `t199_std_tui` HANGS (above), which is its own kind of failure.
  One of the long tail does NOT reproduce by hand: `t345_list_dir_twice` passes
  when its directory is reproduced outside the harness, on both targets, so its
  PE-only failure depends on the harness's own directory state (it lists ".").
  Worth a second look rather than a second guess.
- **What a Windows thread runtime has to replace (round 55, mapped not
  guessed).** `src/y/arch/threads.s` is built on three things with no NT
  equivalent:
    * `%fs:24` is the PER-THREAD HEAP BLOCK, used by `threads.s` (5 sites) AND
      by `prelude.s` (4) -- so it is not the thread runtime that needs a twin,
      it is the ALLOCATOR's per-thread state too. On NT that state lives at
      `%gs:0x30` (the TEB).
    * `clone(2)` for creation, which is what `spawn` reaches today and why
      `t341_threads_slices` page-faults on a NULL read: NT needs
      `NtCreateThreadEx`.
    * futexes for `join`/`mutex`/`sem`, where NT has waitable objects
      (`NtWaitForSingleObject` and friends).
  That is why the item is not a body: it is a second runtime plus the
  allocator's half of it.
- **Y'S OWN TEST FRAMEWORK WAS NEVER IN THE REPOSITORY (round 54).**
  `.gitignore` listed the build artifact `ytest` as a BARE pattern, and in
  gitignore syntax a bare name matches a path component at ANY depth -- so it
  matched the DIRECTORY `src/tools/ytest/` and hid the framework itself.
  `git ls-files src/tools/ytest/` returned ZERO files while
  `src/tools/lsp/` returned 81: `ytest.y` and its `README.md` existed only in
  this working tree, so every `make ytest` in every round built them from an
  uncommitted source, and the objective's "use Y to write Y's own test
  framework" work was by construction uncommittable. The patterns are anchored
  now (`/ycc`, `/cycc`, `/yserve`, `/ytest`, `/ytest-report.md`), which is what
  they always meant -- the built binaries at the root -- and the framework is
  committed.
  A scan of EVERY bare pattern for the same hazard found one more: the bare
  `ycc` also shadowed `test/y/ycc/`, whose fixtures the ycc-units suite reads.
  They were tracked (an ignore does not affect tracked files) so nothing was
  lost, but a NEW fixture added there would have been ignored silently. Both
  are anchored. `git status --ignored` now lists exactly the artifacts.
  Feeding the fix back through a plain string replace is what turned `cycc`
  into `c/ycc` for one commit -- a bare-name pattern is a substring of a
  longer one, so the fix has to match WHOLE LINES. That is the same lesson as
  the suite list, one level down.
- **`./ytest`'s suite list was a hand-kept copy, and it had drifted (round 54).**
  `src/tools/ytest/ytest.y` carried its own list of the suites "run_all.sh
  knows", and `./ytest suites` was running NINETEEN of the twenty-one:
  `treeshake` had been missing for rounds, and `pe-port` was not added when it
  joined `ALL` in round 53. It now READS the list out of `run_all.sh`'s `ALL=`
  line, so there is one source of truth; `./ytest suites` reports 21 run, 0
  failed. Every number `ytest` reported before was a number over 90% of the
  suites.
- **Where the PE target stands, and what is left (round 54).** Measured, not
  guessed:
    * the four thread fixtures (`t341_threads_slices`, `t342_threads_barrier`,
      `t343_threads_queue`, `t344_threads_transfers`) do not merely "fail on
      PE": `t341` PAGE-FAULTS ON A NULL READ at address 0x14000110F, because
      `spawn` reaches `clone(2)` -- a LINUX syscall number -- through
      `src/y/arch/threads.s`, which has no Windows twin at all. That is the
      round-36 class of accident (a raw Linux number in a file both targets
      use) and it is the whole of the "fork/spawn/threads on NT" item: NT needs
      `NtCreateThreadEx`, a TEB-based per-thread heap (`%gs:0x30`, not `%fs`),
      and waitable objects for `join`/`mutex`/`sem`. Nothing small.
    * `t349` was used by TWO fixtures (`t349_fs_stat` from round 38 and
      `t349_random_bytes` from round 50). Basenames are what the native suite
      keys on, so nothing broke, but `random_bytes` is `t350` now.
- **THE PORT GATE HAS A WINDOWS HALF NOW (round 53)**, which is the general
  fix for the hole round 52 fell through: `test/sh/pe-port.sh` compiles the
  whole `test/y/**.y` corpus with BOTH compilers for `--target=windows`, with
  and without `-g`, and requires the PEs to be byte-identical. 1138 checks,
  ~37 s alone, sharded 8 ways under `-j` so the parallel run barely moves.
  It is in `run_all.sh`'s `ALL` list, so `make test` and `make check` run it;
  `make rebless` does not (it runs the port suite only), which keeps the bless
  at 9.5 s.
  **Proved by planting the bug back**, which is the only way to trust a new
  gate: with the hoisted `b[0]` restored, every `-g` case fails and every plain
  case passes -- the exact round-52 signature -- and with the fix in place all
  1138 pass.
- **THE PORT DIVERGENCE IS FIXED (round 52), and pe-gate.sh now catches it.**
  `asm.c`'s `pe_prologue_insn` read `b[0]` BEFORE its own `n < 1` guard:

      ylong b0 = yv_l(ya_get(b, 0));      /* <- empty array: a trap */
      if (n < 1) { return no; }

  so a ZERO-BYTE item -- a line marker, which is exactly what `-g` introduces --
  trapped in `ya_get` and `cycc --target=windows -g` failed on every program
  while the Y copy was fine. The Y has always had the guard first
  (`src/y/asm.y`, `pe_prologue_insn`: `if (n < 1) { no } else if (b[0] == ...`).
  The guard now comes first in the C too, with the reason in a comment.
  Found with gdb in four steps that are worth repeating, because the first three
  were wrong: a conditional breakpoint on the *bounds* condition never fired, so
  the trap was not an overrun; one on `i < 0` never fired either; instrumenting
  `ys_byte_at`'s message changed NOTHING, which proved the failing check was not
  there at all -- and `strings cycc` then showed TWO "index out of bounds"
  messages, the second in `ya_get`/`ya_set`, the ARRAY one. Breaking there gave
  the real backtrace: `pe_prologue_insn` <- `pe_prologue` <- `pe_frame_prologues`
  <- `pe_frames` <- `pe_unwind` <- `pe_image` <- `asm_link`.
  pe-gate.sh now builds the same `-g` program with `./cycc` and requires the two
  PEs to be BYTE-IDENTICAL (they are), which is the check that would have caught
  it at any point in the last ten rounds. It is skipped when `./cycc` is absent.
  Verified: make ycc byte-identical; make port-check green; all 20 suites; the
  gate green with the new line. (A C-only change does not move bench-ir, whose
  two sides are both Y binaries; `make ycc`'s identical output is the evidence
  that nothing else shifted.)
- **The round-51 description of the same bug, kept because the trail is the
  lesson:** `./cycc --target=windows -g FILE` TRAPS where `./ycc` succeeds.**

      $ ./cycc --target=windows -g hello.y -o /tmp/g.exe
      runtime error: index out of bounds

  `hello.y` is `print(7);`. Without `-g` the same command works, the Y compiler
  works with or without `-g`, and `pe-gate.sh` never saw it because it builds
  its `-g` PE with `./ycc` -- so this is a hole in the PORT GATE rather than in
  the PE path: the port suite compiles the corpus for Linux only, and a
  divergence that needs `--target=windows -g` is invisible to it.
  Where it is, from gdb: `ys_byte_at` (src/c/yv.c:397) is called with
  `i >= s->u.s.n` from `words_scan` at src/c/native.c:920 -- the first statement
  of its scan loop, `ylong c = ys_byte_at(code, i);` -- reached from
  `words_seen` (native.c:905) and `resolve_unit` (native.c:728). The value IS a
  string (`code->tag == Y_STR`, `n == 9`, and the conditional breakpoint on
  `code->tag != Y_STR` never fires), so the scan is reading past the END of its
  own text rather than being handed the wrong type. The Y twin's loop head is
  `let c = byte_at(code, i);` under the same `while (i < n)`, so the two scans
  differ somewhere between those two lines -- and the next step is the
  line-by-line comparison of `words_scan` in `src/y/native.y` (line 209 on) and
  `src/c/native.c` (line 912 on), which is what this round should have done
  instead of chasing the breakpoint. The Y is the reference: whatever it does,
  the C has to do, and `test/sh/cycc-win.sh` (W1) is where a fixture for this
  belongs once it is fixed.
  Nothing is committed for it: the tree is unchanged and make ycc verifies
  byte-identical.
- **`std/crypto` RANDOMNESS WORKS ON NT (round 50), by NOT using bcrypt.** The
  body is `RtlGenRandom`, which advapi32 exports by the name
  `SystemFunction036`:

      BOOLEAN SystemFunction036(PVOID RandomBuffer, ULONG RandomBufferLength)

  ONE call -- no provider, no handle, no close -- which is exactly the dance
  wine cannot do. Measured on a PE: `crypto.random_bytes(16)` gives 16 bytes,
  non-zero, two draws that differ, `bytes_eq(a, a)` true and 0 bytes for a
  zero-length request, byte-identical to the Linux run through getrandom(2).
  `test/y/native/t349_random_bytes.y` is the dual-target fixture, so this is
  now covered by the native suite as well as by hand.
  The bcrypt import is GONE from `w_imports()`: nothing calls it, and a dead
  IAT cell is dead weight. The goal's "std/crypto on BCrypt" is satisfied
  functionally -- randomness works -- but not literally, and the reason is
  measured rather than assumed: both routes into wine 11.17's bcrypt
  page-fault with the arguments demonstrably right (see the entry below).
  Two bugs on the way, both this project's own recurring ones:
    * the C twin's `w_imports()` used `yav(2, ...)` while appending a THIRD
      record, which SILENTLY DROPS it -- the exact hazard PORTING.md and
      yv.h's comment warn about, and the reason `yavs(..., NULL)` exists. The
      symptom was an assembler error naming an undefined `y_iat_SystemFunction036`,
      i.e. a missing import cell, not a runtime surprise.
    * and the first fix passed three records to `yavs` WITHOUT THE NULL
      sentinel, which segfaults the compiler. A variadic list has two ways to be
      wrong and both are silent until they are not.
- **BCrypt on wine: `OpenAlgorithmProvider` WORKS and is MEASURED, so round
  35's diagnosis was wrong; `GenRandom` is what fails, and the next step is a
  different entry point entirely.**
  Round 35 concluded that "the call that ran was not the function the label
  names -- the cells and the offsets disagree". That is DISPROVED by
  measurement: a temporary body that made the Open call and wrote its results
  into the caller's buffer (dumped through a helper in std/fs.y, which is read
  from source and needs no rebless) got **status 0 and handle 227328
  (0x37800)** -- a real handle from a real bcrypt. The deterministic .bss IAT,
  `FirstThunk` pointing at it, the three-import table and the Win64 call are all
  working; pe-gate.sh asserts the first two.
  What still fails is `BCryptGenRandom(h, buf, len, 0)` with that SAME valid
  handle: wine's bcrypt page-faults on a handle of -1 inside its own code
  (address 0x6FFFFF9D514B), and round 35 measured that the documented
  pseudo-handle (BCRYPT_USE_SYSTEM_PREFERRED_RNG = 2) page-faults too. So both
  routes into wine 11.17's bcrypt fail, the arguments are demonstrably right,
  and the blocker is the library rather than this layer. The body is reverted
  again; the tree is the round-48 state and make ycc verifies byte-identical.
  **The concrete next step is to stop using bcrypt: `SystemFunction036`
  (`RtlGenRandom`) in advapi32.dll** is the classic Windows RNG, it is present
  in this prefix, and its signature is `BOOLEAN SystemFunction036(PVOID, ULONG)`
  -- ONE call, no provider, no handle, no close, and therefore none of the
  three-call dance that wine cannot do. It needs one more entry in
  `w_imports()` and a body about ten instructions long.
  **And a method lesson that cost this round an hour:** the edit that tried to
  insert the body used `s[:i] + body`, which TRUNCATES the file at the block --
  and `y_os_random` sits in the middle of wsys.s now, so it silently deleted the
  ten bodies added since round 42. The build still succeeded (a missing body just
  falls back to the ELF one), every test still ran, and only grepping for
  `y_os_list` showed it. Replace a block by matching its exact text, never by
  index-and-truncate; restore from `git checkout` (the /tmp backup was damaged
  by the same splice) and treat "the compiler still has the old body" as a
  suspicion about the SOURCE before the build.
- **B2's FILE LAYER IS DONE (round 48). `pe-fs.y` MATCHES LINUX EXACTLY.** The
  45-line portable file-path program that pe-gate.sh has carried as a known gap
  since round 39 -- when it stopped failing and started TIMING OUT -- now
  produces the Linux transcript line for line, and the two "known gap" exits in
  pe-gate.sh that used to report and return 0 are FAILURES again. That check is
  a hard gate for the first time in ten rounds, and the whole gate is green:

      pe-gate: file path ok (45 lines, PE == the Linux output)
      pe-gate: import table ok (KERNEL32.dll!GetCurrentProcessId, bcrypt.dll!BCryptGenRandom)
      pe-gate: IAT at .bss 00006000 ok
      pe-gate: -g sections ok (.debug_l has its bytes)

  Two things in pe-gate.sh had to be right for that, and neither was: the
  file-path program runs in a FRESH directory now (it lists ".", so a leftover
  from the round-trip check changed the answer -- a property of the test, not of
  the layer), and the IAT assertion's RVA arithmetic was wrong in a way that had
  never mattered because the assertion had never run for real: the low eight hex
  digits of the VMA 0x140006000 are 0x40006000, not the RVA, so it compares
  a hex string against a decimal number. It is `printf '%08x' $((16#$vma -
  0x140000000))` now.
  The last thing it needed was not a body: all thirteen entries already had one
  after round 47. It was that **NT's kernel does not resolve `.` or `..`** --
  a relative name is an object name, taken literally -- so `fs.list_dir(".")`
  answered none and `chdir("..")` answered false. `y_w_path` now walks the
  relative part ONE COMPONENT AT A TIME: `.` is dropped, `..` pops the previous
  component, components are joined by a single separator added only when the
  path so far does not already end in one, and a pop never goes above
  `\??\X:\` (seven units: four for the prefix, three for the drive root).
  Two bugs fell out of that, both the same shape as this layer's earlier ones:
    * appending the separator unconditionally in y_os_chdir produced
      `...\w49\\` when the path already ended in one -- and fs.cwd drops ONE
      trailing separator, as getcwd(2) does, so it reported `Z:/tmp/ts/w49/`.
      Every relative path after that was resolved against a directory whose name
      ends in a slash: reads and writes still worked, and removing a file in it
      failed. A wrong answer that looks almost right.
    * a `#` comment inside a `#=== replace:` block is `unexpected comment
      (backend bug)`; comments go ABOVE the marker. That rule has now been
      broken four times, once per round of asm work.
- **`y_os_list` WORKS (round 47), so ALL THIRTEEN named-layer entries fs.y
  calls now have Windows bodies.** B2's file layer is complete: read, write,
  stat, openat, close, mkdir, unlink, set_mode, lseek, rename, getcwd, chdir
  and list.
  And the payoff is measurable: `test/sh/pe-fs.y`, the 45-line portable
  file-path program that pe-gate.sh has been reporting as a known gap since it
  started TIMING OUT in round 39, now RUNS TO COMPLETION under wine and matches
  the Linux transcript on all but FOUR lines.
  THE FOUR ARE ONE PLATFORM DIFFERENCE, not a missing body: NT's native API does
  not resolve `.` or `..` -- that is user-space work
  (RtlDosPathNameToNtPathName) and there is no user space here -- so
  fs.list_dir(".") answers none and chdir("..") answers false, where Linux
  resolves both, and two later lines fail as a consequence of the second. That
  is the whole remaining diff, and `y_w_path` normalising those components in the
  rebuilt path is what closes it.
  HOW IT WAS FOUND, because the method is the point: the body rewrites the
  caller's buffer IN PLACE, so every dump taken AFTER a call showed the walk's
  own output rather than the kernel's, and two rounds of guessing at offsets
  produced nothing. What settled it was a TEMPORARY body that made the
  NtQueryDirectoryFile call and returned WITHOUT TOUCHING THE BUFFER, dumped
  through a helper in std/fs.y (read from source, so no rebless). That showed
  FILE_BOTH_DIR_INFORMATION exactly as documented -- NextEntryOffset (+0) = 96,
  FileAttributes (+56) = 16 for ".", FileNameLength (+60) = 2 bytes, FileName
  (+94) = 46 00 -- and the walk was then a transcription rather than a guess.
  FileNamesInformation (12) is NOT what wine answers for this call; class 3 is.
  Two more things this body needed, both already-known rules: the frame must be
  128 bytes so that NtQueryDirectoryFile's SEVEN stack arguments at 40(%rsp) and
  up land clear of the IO_STATUS_BLOCK at -32, and the length has to survive the
  syscall in a frame slot rather than in %rcx or %r11.
- **The `y_os_list` measurement that came before (round 46), kept for the
  method:** It is the LAST of the thirteen, and the only one
  without a Windows body.
  What is established:
    * the call is `NtQueryDirectoryFile` (53), eleven arguments: four in
      registers and SEVEN on the stack at 40(%rsp) and up, which is why the
      frame has to be 128 bytes with the IO_STATUS_BLOCK at -32 -- the
      round-44 rule again.
    * THE NUMBER AND THE ARGUMENTS ARE RIGHT. With a 64-byte buffer the kernel
      rejects the call (the body answers -1) and with the caller's 32760 it
      returns records; a wrong syscall number or a misplaced argument does not
      behave that way.
    * FileNamesInformation (12) does NOT come back as
      FILE_NAMES_INFORMATION on wine 11.17: the walk read
      NextEntryOffset/FileIndex/FileNameLength at +0/+4/+8 and got garbage,
      so it emitted the whole buffer as one name. Class 3
      (FileBothDirectoryInformation, length at +60 and name at +94) was tried
      next and the header words were garbage too.
    * ...AND THAT SECOND MEASUREMENT IS WORTHLESS AS TAKEN, because the body
      REWRITES THE BUFFER IN PLACE. Whatever the kernel wrote is destroyed by
      the walk before any diagnostic can look at it, so every dump of that
      buffer after a call shows the walk's own output, not the kernel's. **The
      next attempt must look at the raw buffer FIRST**: a temporary
      `y_os_list` that makes the call and returns immediately, dumping the
      first few dozen bytes through a helper in std/fs.y (which is read from
      source, so the experiment needs no rebless). That is the one experiment
      this round should have run and did not.
  Twelve of the thirteen entries have Windows bodies; the known-gap report in
  pe-gate.sh names y_os_list as the one that does not. Nothing was committed
  for it: the tree is the round-45 state, make ycc verifies byte-identical, and
  no rebless was needed.
- **`y_os_getcwd` and `y_os_chdir` work (round 45)**, so TWELVE of the thirteen
  entries have Windows bodies and ONE does not: **`y_os_list`** -- the last of
  the directory trio and the fiddliest, since fs.list_dir's contract is one
  format on both kernels (NUL-terminated names, "." and ".." left out) and NT
  hands back FILE_BOTH_DIR_INFORMATION records that have to be rewritten into
  it.
  `fs.cwd()` answers `Z:/tmp/ts/w45` where Linux answers `/tmp/ts/e39` -- the
  same shape, which is all a shared fixture can compare -- and `fs.chdir` moves
  the process, fails for a path that is not a directory, and leaves the
  directory alone when it fails. Both are in pe-gate.sh's round trip.
    * getcwd is not a syscall at all: the current directory is a PEB field
      (ProcessParameters+56, a UNICODE_STRING whose Length in BYTES is at +56 and
      whose Buffer is at +64). The DOS path is narrowed to ASCII, its separator
      turned around to `/` so the string fs.cwd returns is the shape the rest of
      fs.y expects (y_w_path turns it back), and the TRAILING separator dropped,
      which is what getcwd(2) returns.
    * chdir is a PEB WRITE, so its buffer has to outlive the call: it is
      allocated with NtAllocateVirtualMemory (24) and the PEB is pointed at it.
      chdir therefore LEAKS the previous directory's buffer, bounded by the
      number of chdirs a program makes -- the honest price of having no
      allocator here. The `\??\` prefix y_w_path adds is skipped rather than
      stripped (four units, eight bytes), because the PEB holds a DOS path.
    * `..` IS NOT RESOLVED, and that is a real difference rather than a bug to
      fix here: NT's native API does not do it -- that is user-space work
      (RtlDosPathNameToNtPathName), and there is no user space in this layer. So
      `chdir("..")` is true on Linux and false here, and the fixture deliberately
      does not test it. Resolving it means normalising the path in the body.
  Two bugs on the way, both the same shape as earlier ones: the copy wrote ONE
  byte per unit where a PEB field needs UTF-16 (two bytes), and the length was
  read out of %rdx after the PEB read had used it, so Length became a stray
  character from the copy loop -- with chdir still reporting success while the
  directory came out as the wrong path.
- **`y_os_rename` WORKS (round 44)**, so TEN of the thirteen entries have
  Windows bodies and THREE do not: `y_os_getcwd`, `y_os_chdir`, `y_os_list` --
  the directory trio. Verified byte-identical on ELF and PE: write a file,
  rename it, the source is gone, the target has the content, renaming a missing
  source fails, and a DIRECTORY renames too. `pe-gate.sh`'s fixture covers it.
  Round 43's diagnosis was right about the mechanism and wrong about the state:
  **the frame was the whole bug.** With `sub $4800`, NtCreateFile's stack
  arguments at 40(%rsp) land on rbp-4760 -- the block's own IO_STATUS_BLOCK --
  and the call overwrites what it is about to be handed, answering
  STATUS_INVALID_PARAMETER (0xC000000D), which reads exactly like a bad path.
  `sub $5200` puts the argument area at rbp-5160 and everything works. The
  "5200 did not fix it either" in that round's note came from a hand-edited
  block that the edit itself had mangled; rebuilding the block from scratch is
  what showed it. Two more real bugs in the same block, both fixed and both
  worth remembering:
    * the second y_w_path call clobbers %r8, which held the SOURCE's unit count,
      so the open was handed the TARGET's length;
    * FileNameLength is at struct+16 and the name is INLINE at +20, so that
      field is written a BYTE at a time -- an 8-byte store runs into the name.
- **`y_os_lseek` works (round 43)**, so NINE of the thirteen entries have
  Windows bodies and FOUR do not: `y_os_rename`, `y_os_getcwd`, `y_os_chdir`,
  `y_os_list`. Verified byte-identical on ELF and PE for all three whences --
  SEEK_SET to 3, SEEK_CUR reading back 3, SEEK_END reading the size 10, a
  position past the end (legal), and a negative position (refused) -- and
  `pe-gate.sh`'s fixture covers it.
  Windows has no lseek, so it is a query/set pair: NtQueryInformationFile (17)
  reads the position (FilePositionInformation, class 14, an 8-byte
  LARGE_INTEGER) and NtSetInformationFile (39) writes it, while
  FileStandardInformation (class 5) carries the SIZE at offset 8 of its 24
  bytes for SEEK_END. `add` takes no memory operand in this assembler, so the
  offset is loaded into a register first.
- **`y_os_rename`: written, did not work, reverted -- and it found a hazard that
  applies to EVERY NtCreateFile block.** It opens the source with DELETE access
  and sets FileRenameInformation (class 10), whose information is
  FILE_RENAME_INFORMATION with the target path INLINE at +20 and FileNameLength
  a byte at a time at +16 (an 8-byte store there runs into the name). Two real
  bugs were fixed on the way -- the second y_w_path call clobbers %r8, which
  held the SOURCE's unit count, so the open was handed the target's length; and
  the length must survive the syscall in a frame slot. Neither was the failure:
  **the stack arguments go at 40(%rsp), so a 4800-byte frame puts them at
  rbp-4760, which was that block's IO_STATUS_BLOCK** -- the call overwrote the
  block it was about to be handed and answered STATUS_INVALID_PARAMETER
  (0xC000000D), which reads exactly like a bad path. Enlarging the frame to 5200
  did not make rename work either, so something else is also wrong, but the rule
  is now written down where it belongs: **an NtCreateFile frame must be deeper
  than the stack-argument area is far down, or the arguments land on the block.**
  `y_os_lseek`'s own 80-byte frame puts 40(%rsp) at rbp-40, which clears its
  IO_STATUS_BLOCK at -32 by eight bytes -- it works, and it is worth knowing
  that it is that close.
- **`y_os_mkdir`, `y_os_unlink` and `y_os_set_mode` work (round 42)**, so EIGHT
  of fs.y's thirteen layer entries now have Windows bodies and FIVE do not:
  `y_os_lseek`, `y_os_rename`, `y_os_getcwd`, `y_os_chdir`, `y_os_list`.
  Verified byte-identical on ELF and PE: make_dir (and make_dir again FAILING,
  because that is what mkdir(2) does), is_dir, write a file inside the new
  directory, read it back, remove_file, remove_dir, and exists false afterwards.
  `pe-gate.sh`'s round-trip fixture covers all of it.
  How they are built, both reusing the openat frame and its measured rules:
    * mkdir is NtCreateFile (85) with FILE_CREATE (2) and FILE_DIRECTORY_FILE
      (1) -- FILE_CREATE deliberately, so an existing directory fails -- then
      NtClose (15) on the handle it returns.
    * unlink is TWO calls: open with DELETE access (65536) and FILE_OPEN, then
      NtSetInformationFile (39) with FileDispositionInformation (13), whose
      information is a SINGLE BYTE (BOOLEAN DeleteFile). FILE_DIRECTORY_FILE
      (1) or FILE_NON_DIRECTORY_FILE (64) comes from arg3, which is a boolean
      rather than the flag the ELF body translates. A directory still has to be
      empty, as rmdir(2) requires.
    * set_mode returns 0 and does nothing, in writing rather than by falling
      through to the ELF body: NT permissions are an ACL, chmod is
      unimplemented rather than failing, and a caller handed a Linux errno out
      of a Windows syscall is being told nothing.
- **`y_os_openat` WORKS (round 41), and two rounds of the record were wrong.**
  Round 39's commit message says the body was "written and REVERTED". It was
  not: the revert restored a backup that had been taken AFTER the body was
  appended, so the broken `y_os_openat` and `y_os_close` stayed in the tree and
  were BLESSED. The observable consequence was recorded in that same commit
  without being connected to its cause -- `pe-gate.sh`'s file-path program
  changed from failing to TIMING OUT. Round 40 then said "wsys.s is back to its
  committed state", which was true and beside the point: the committed state
  contained the body, so round 40's measurements describe it (they hold) and its
  "fresh rewrite" landed next to it, which is why the assembler reported
  `symbol 'y_os_openat' is already defined` this round.
  The lesson is about `cp` as a revert: a backup taken after the change is not a
  backup of before it, and a commit message that says "reverted" without
  checking the file is a claim, not evidence. `git show HEAD:src/y/arch/wsys.s |
  grep -c 'yoap_fail:'` answers it in one line.
  **What it actually took**, all six measured:
    1. TWO ATTEMPTS at the disposition. FILE_OVERWRITE (4) for O_TRUNC, else
       FILE_OPEN (1); only NAME_NOT_FOUND (0xC0000034) with O_CREAT triggers
       FILE_CREATE (2); only COLLISION (0xC0000035) retries the first shape.
       Wine's NtCreateFile treats FILE_OPEN_IF (3) and FILE_OVERWRITE_IF (5) as
       open-only -- both answer NAME_NOT_FOUND for a file that is not there,
       while FILE_CREATE on the identical call creates it.
    2. EVERY argument is set again for the retry, not just the disposition. A
       second syscall cannot assume the stack area below rsp survived the first:
       the retry answered STATUS_INVALID_PARAMETER while the first answered
       NAME_NOT_FOUND, and 48(%rsp) is FileAttributes.
    3. FILE_SYNCHRONOUS_IO_NONALERT (32) in CreateOptions. Without it the handle
       is asynchronous, NtWriteFile answers STATUS_PENDING instead of writing,
       and the program gets a zero-byte file with the create having succeeded.
    4. y_os_close (NtClose, 15). fs.y's write_file is open, write, CLOSE, and
       without this body the close falls into the ELF one -- Linux syscall 3,
       which on NT is an unimplemented ntdll function, so wine ABORTS after the
       file is written and it reads as "the write failed" when it did not.
    5. Comments only ABOVE the `#=== replace:` marker: a `#` line inside a
       replaced region reaches the in-tree assembler, which has no comment
       syntax and reports `unexpected comment (backend bug)`.
    6. NTSTATUS immediates must be the SIGNED form -- `cmp $-1073741772, %eax`
       for 0xC0000034 -- because the number reader rejects anything that does not
       fit in 32 signed bits, and 0xC00000xx never does.
  Verified: `fs.write_file`, `fs.read_file`, `fs.append_file` and `fs.file_size`
  produce byte-identical output on ELF and PE over a real file (create, write,
  read, append, read, size 29, open, close), and `pe-gate.sh` now checks exactly
  that with `test/sh/pe-fsrt.y` against its Linux output. `fs.open_file` on an
  existing file and STATUS_OBJECT_PATH_NOT_FOUND for a missing directory were
  already working and still are.
- **`y_os_openat`: what round 40 measured, and the one thing still unexplained.**
  The round-39 statuses (NAME_INVALID etc.) came from calling `os_call`
  DIRECTLY from a plain program, and that channel is NOT reliable: a direct
  `os_call("y_os_stat", ...)` returns -1 while the identical call made from
  inside fs.y succeeds. Every conclusion has to come through the real API
  instead, which is how these were taken (by returning the raw NTSTATUS from
  the body's failure path, since `fs.open_file` passes a positive value through
  as if it were an fd):
    * opening an EXISTING file works -- `fs.open_file("src/y/std/fs.y", "r")`
      returns a handle
    * a missing directory answers STATUS_OBJECT_PATH_NOT_FOUND (0xC000003A),
      correctly
    * CREATING fails, with STATUS_OBJECT_NAME_NOT_FOUND (0xC0000034), for BOTH
      FILE_OPEN_IF (3) and FILE_OVERWRITE_IF (5) -- and this is the finding:
      **wine's NtCreateFile treats both as open-only.** Forcing FILE_CREATE (2)
      on the identical call CREATED the file, so the disposition does arrive and
      the object layout, the access mask and the path are all right.
    * the file that FILE_CREATE created was ZERO BYTES, so the write half of the
      round trip also does not work on a file handle. The handle is asynchronous
      unless FILE_SYNCHRONOUS_IO_NONALERT (32) is in CreateOptions, and
      NtWriteFile on an asynchronous handle answers STATUS_PENDING rather than
      writing.
  The fix those facts imply -- FILE_CREATE (2) for the O_CREAT cases with a
  fallback to FILE_OPEN (1), or FILE_OVERWRITE (4) when O_TRUNC, only on
  STATUS_OBJECT_NAME_COLLISION (0xC0000035), plus FILE_SYNCHRONOUS_IO_NONALERT
  in CreateOptions -- was written and DID NOT WORK: every open, including the
  one that worked before, came back -1, and that regression is the thing to
  explain first next time rather than rebuilding the same patch. The candidate
  is the line-surgery that applied it (the O_CREAT tail and the O_EXCL arm were
  rewritten by hand); the facts above are independent of it and stand.
  This is also why the direct-call channel matters: with it, the same symptom
  reads as a body bug, and through the real API it reads as a wine disposition
  quirk. The first reading cost a round.
- **The same helper is what the other ten need**: `y_os_openat`, `y_os_close`,
  `y_os_lseek`, `y_os_mkdir`, `y_os_unlink`, `y_os_rename`, `y_os_getcwd`,
  `y_os_chdir`, `y_os_list`, `y_os_set_mode`. The path-building half is now
  written and proven (in `y_os_stat`); the directory half is
  NtQueryDirectoryFile with a handle from NtCreateFile, and `getcwd`/`chdir` are
  PEB reads (the DOS path is already being read for the prefix).
- **The failed first attempt, kept for the record:** The body widened the path to UTF-16 on the stack, built an
  OBJECT_ATTRIBUTES (Length 48, RootDirectory NULL, OBJ_CASE_INSENSITIVE) and a
  UNICODE_STRING, and called `NtQueryFullAttributesFile`, filling the two fields
  `fs.y` reads (st_mode at byte 24, st_size at 48 from EndOfFile). With the
  right number and correct structures it answers **STATUS_OBJECT_PATH_SYNTAX_BAD
  (0xC000003B)**, which is the whole finding: the kernel does NOT resolve a
  relative name against the process's current directory -- that is user-space
  work (`RtlDosPathNameToNtPathName`) -- so the body must build an ABSOLUTE NT
  path: `\??\` then the current directory's DOS path from the PEB
  (`%gs:96` -> ProcessParameters at +32 -> CURDIR.DosPath at +56, a
  UNICODE_STRING whose Length is at +56 and Buffer at +64) then the relative
  part, all UTF-16. That helper is what `y_os_openat`, `y_os_mkdir`,
  `y_os_unlink`, `y_os_rename` and `y_os_list` need too, which is why it is the
  first thing to write rather than the last.
- **CORRECTION to the entry below, and it is the important one.** The claim
  that the PE failure was environmental was WRONG, and the comparison it rested
  on was invalid: I rebuilt the file-path program with `refs/ycc.ref` *after*
  that ref had been reblessed with the import plumbing, so both sides carried
  the change. Built instead from a worktree at the commit *before* any import
  work (`0ca9cf9`), the same program runs to completion under wine -- 45 lines,
  exit 0, matching the Linux output -- while the current tree aborts with a wine
  crash dump and 108 lines of noise. So the plumbing did perturb it. What it
  perturbed is an ACCIDENT, and that is the real finding:
  **`wsys.s` has Windows bodies for only 2 of the 13 named-layer entries
  `fs.y` uses** (`y_os_read`, `y_os_write`). The other eleven --
  `y_os_openat y_os_close y_os_lseek y_os_stat y_os_mkdir y_os_unlink
  y_os_rename y_os_getcwd y_os_chdir y_os_list y_os_set_mode` -- fall through to
  their ELF bodies, which are raw LINUX syscall numbers, and on NT whatever
  those numbers mean is what runs. Measured on the pre-import build:
  `fs.cwd()` answers a non-empty string whose first byte is `'Z'` (90), not
  `/`. The file-path check passed in rounds 31-33 because those accidents
  happened to produce the Linux output; the plumbing moved the `.bss` under it
  and the accident stopped being benign.
  `pe-gate.sh` now REPORTS this instead of failing, naming the eleven entries,
  so the rest of the file stays a gate. **Implementing those eleven NT bodies
  is the concrete next B2 step**, and until they exist no PE file-I/O check
  means anything.
- **And the older entry, kept only because it is what a wrong comparison cost:**
  its file-path program dies with

      wine: Call from 0000000140001A9B to unimplemented function
      ntdll.NtMapUserPhysicalPagesScatter, aborting

  which is the self-test doing exactly what it was built for: it calls one Nt
  function per class to prove the pinned `w_sysno` numbers, and this wine's
  ntdll does not implement that one. Proven environmental by rebuilding the
  file-path program with `refs/ycc.ref` -- the ROUND-33 reference, before any
  of the import work -- which crashes at the same address 0000000140001A9B.
  The gate passed in rounds 31--33 on this same host, so something outside the
  repository (a wine update, or the prefix the `winetricks` experiment left
  behind) changed between then and now. It is worth fixing before the next PE
  work: either the pinned number is stale for this ntdll or wine regressed, and
  the self-test is the only thing that can tell us which.

### Yet to do

- **A compiler CSE pass for `prod_err` in general.** The targeted manual
  hoisting above is done; the general case ("split the same value once even
  when the two uses are in different call sites") is a compiler change, not a
  std one, and is deliberately not attempted.
- No known correctness gap. The math suite reports `worst gap 1 ulp, 0 over 1`.

---

## 3. `meta-win` — done / doing / yet to do

**The branch is two features in one history:** `#{ … }#` compile-time code
generation (`meta`), and Windows support (`win`), plus LSP and docs work.

### Done

- **`M1`/`M2` — the meta pass.** `src/y/meta.y`: a `#{ … }#` block is compiled
  and run in a forked child over an in-RAM image; what it prints is spliced
  into the source. Top-level only, nesting is splicing (cap 8), mid-token
  blocks hoist the call, `ycc run` and `ycc -E` are the run and dump modes.
  29 `meta` fixtures plus the diagnostics; `test/sh/runcheck-meta.sh`,
  `mem-meta.sh`, `meta-identity.py`.
- **Windows Phase A / `W2`–`W4` core.** `src/y/pe.y` + `src/c/pe.c` (PE32+
  writer, `.pdata`/`.xdata` unwind info, no `.reloc`), `--target=windows`,
  `src/y/target.y`/`target.c`, the Windows half of `arch_x64.y` and
  `src/y/arch/wsys.s` (19 replacement/addition blocks).
- **`B1` — the named syscall layer for the four packed units.** `os_call` plus
  `y_os_*` labels, so `rt`, `prelude`, `exec` and `str` are target-independent
  and the std pack stays shared. `test/sh/pe-packinv.sh` measures the invariant.
- **`argv()` on PE** — read from the PEB's command line rather than the kernel
  stack.
- **`fs.y` partially on the layer** — `open`/`close`/`read`/`write`/`lseek`
  go through `os_call` now (the tip's last two commits).
- The branch's Windows gates, runnable by hand: `pe-gate.sh` (hello-world PE
  under wine), `pe-fixtures.sh` (every `t*` fixture both ways),
  `pe-packinv.sh`, `run-parity.sh`.
- The LSP settings/fixes and the docs that rode along.

### In progress at the tip

- **`B2` — the remaining std units onto the named layer.** Raw `syscall(`
  sites still in `std`: `tui.y` 29 and `net.y` 21, and those are the two that
  genuinely need a new NT design (console API calls and Winsock, neither of
  which is a syscall). **`http.y` and `tls.y` are off the list**: their four
  raw sites were `syscall(1, ...)` and `syscall(0, ...)` -- write and read --
  which the layer already had as `y_os_write`/`y_os_read`, so routing them
  needed no new bodies at all. Every file-descriptor I/O site in `std` is now
  on the layer; only the console and the sockets remain.
  **`crypto.y` is off the list**: its one raw site was `getrandom`, now
  `os_call("y_os_random", buf, len)` with the Linux body in `prelude.s` and a
  Windows body in `wsys.s` that answers ENOSYS (-38, the file's established
  answer-for-unimplementable). The refusal is deliberate rather than lazy:
  NT's source is `BCryptGenRandom`, a **DLL export**, and the PE writer emits
  no import table yet -- so the alternative was to seed from the clock and the
  TSC, and a cryptographic RNG that returns predictable bytes is worse than
  one that returns nothing. `std/crypto.y`'s `random_bytes` now **fails
  closed** on a non-positive answer, which also fixed a latent bug: the old
  loop ignored failures, so on a target whose raw 318 meant something else it
  would take a positive NTSTATUS for a byte count (garbage), and on ENOSYS it
  would spin forever. A PE now prints `runtime error: no randomness source on
  this target` and exits 1.
  (`fs.y` reads 0 raw sites now, not 11 -- that count was stale.)

  **A correction to that commit's number, because the first explanation was
  wrong.** `bench-ir` after the change reads `hello.y +0.37%` (5 907 794 ->
  5 929 909 exact compile instructions), and the commit message attributed it
  to "the crypto unit's error path". It cannot be: `bench/y/hello.y` is
  `print("hello");` and imports nothing, so no line of `std/crypto.y` is in
  that compile. The delta is real (instruction counts are exact, not noisy)
  and it is NOT yet attributed -- the candidates are the compiler's own
  allowlist change (`os_call_names` gained an entry) and the larger embedded
  arch text (`prelude.s` and `wsys.s` both grew a block), neither of which has
  been measured apart. What is measured is the shape: `ycc.y` -0.01% (a
  5.6-billion-instruction self-compile), so it is a small fixed cost, not a
  per-input one. The lesson is the one this file keeps teaching: a number from
  `bench-ir` is a fact, and the sentence explaining it is a hypothesis until it
  is attributed to a phase.

### Yet to do

| item | why it is open |
|---|---|
| **`B2`** the rest of the named-syscall layer | the work above; needs NT bodies for `newfstatat`, `getdents64`, `mkdirat`, `renameat`, `unlinkat`, `fchmodat`, `getcwd`/`chdir`, console `readline`, `exec`, threads/`fork`, net, crypto |
| **`W1`** `cycc.exe` under mingw-w64 | **DONE for non-meta programs.** `x86_64-w64-mingw32-gcc` is installed, `make cycc.exe` builds from the same `src/c`, and `test/sh/cycc-win.sh` reports 557 same / 6 different over the corpus. All 11 are the meta fixtures: their M1 runner forks and maps a memfd, which is the NT `fork`/`mmap` work below. |
| **`W5`** the std split | largely superseded by `B1`'s named layer for the packed units; the rest is `B2` |
| **`W6`** the Windows harness | job-object memory cap (`ulimit -v` has no Windows equivalent), a PE `test_debug.sh` branch, `llvm-*` tool swap. **A version-pinned prefix is done**: `winetricks` is installed here, and `WINEPREFIX=~/.wine-win10 winetricks -q win10` gives a Windows-10 profile to run the PE gates against. Measured: a ycc-built PE prints `pe ok` / `true` and exits 0 under both the default prefix and the win10 one, and the W3 self-test stays silent in both -- so the `w_sysno` numbers pinned to one ntdll sample hold under a version-pinned prefix too. No script change is needed: `wine` reads `WINEPREFIX` from the environment, so `WINEPREFIX=~/.wine-win10 ./test/sh/pe-gate.sh ./ycc` is the whole recipe. (The prefix is 1.7 GB, so it is created when wanted rather than kept; the default `~/.wine` is what the committed gates use.) |
| **`w_self_test_lines()`** | **DONE.** `src/y/arch/wselftest.s` (5.2 KB) is the probe: one `Nt*` call per class, once at program start, each NTSTATUS checked, so a stale `w_sysno` number that now names a different real Nt function fails by name in the first instruction instead of surfacing later as wrong memory. `arch_x64.y`'s `w_self_test_lines` returns the lines (and `arch_x64.c` its twin), `native.y` feeds them to the prelude so the tree shaker keeps `y_os_write`/`y_os_exit`, and the `_start` prologue calls `y_w_self_test` on the Windows target only -- no lines and no call are emitted for an ELF. `pe-gate.sh` is the gate: a PE must load, run, and NOT print the self-test's message. |
| **`fork`/`spawn`/threads on NT**, `std/crypto` on BCrypt, console `readline` | per-call redesigns, listed in `ideas/WINDOWS.md` |
| **PDB**, `--target=macos`, PE-side program profiling | explicitly deferred by the design |

### Finished in this pass on the Windows side

- **The encoder guard the design claimed existed.** `pe.y`'s comment said the
  fixup kinds were "enumerated in `asm.y`'s `pe_no_abs`", but no such function
  existed: an unknown absolute fixup would have been written as a difference of
  two labels and truncated to 32 bits. `pe_no_abs` now exists in `asm.y` and
  `asm.c`, and `patch_item_kind2` refuses any kind outside
  `rel32`/`rel8`/`rip32`/`imm32diff` by name. It is output-neutral (all four
  kinds are position-independent), so every emitted binary is unchanged.
- **`W1` — `cycc.exe`.** The C copy now cross-builds for Windows and runs under
  wine. The keystone was `src/c/ylong.h`: Windows is LLP64, so C's `long` is 32
  bits where the whole value model needs 64 (12 overflow sites, a `jmp` that
  became 32-bit and would not assemble, and any long past 2^31 wrong). With
  `ylong` (and the host shim of commit `0a74bd4`) `make cycc.exe` is the same
  compiler for a second host. `test/sh/cycc-win.sh` is the gate; `-S` is
  byte-identical too. `-g` is not compared across hosts (DWARF records the host's
  own absolute path).
- **A child's stdio: `popen`/`pwrite`/`pclose_in`/`pread`/`pclose` and
  `exec_capture`/`exec_capture_in`** in `std/exec.y`, over a new `y_os_pipe` and
  `y_os_dup2` in the named layer (Linux in `prelude.s`, ENOSYS in `wsys.s`), so
  a Y program can run a tool and read its answer. Fixture
  `test/y/native/t333_exec_pipe.y`.
- **The two false comments.** `w_self_test_lines`'s comment (and the sentence
  in `arch_sysno` that pointed at it) described a probe nobody runs; both now
  say the probe is unimplemented and why that is a real gap. The C twin's
  comment referenced a "work report" that is not in the tree; the two copies
  now match.

---

## 4. Verification

```sh
make cycc          # the C copy builds (3 pre-existing unused-parameter warnings)
make ynew          # generations 2 and 3 byte-identical
make port-check    # cycc and ynew agree on every fixture: ALL SUITES PASSED (port)
./test/sh/pe-gate.sh ./ynew    # 4100-byte PE, .pdata/.xdata, runs under wine, exit 0

# the full suite (19 suites) on the merged tree — run with a fresh /tmp:
unshare -rm sh -c 'mount -t tmpfs tmpfs /tmp
  cd '"$PWD"'
  YPORT_SELF=0 CYCC=$PWD/cycc YREF=$PWD/ynew YCC=$PWD/ynew YSELF=$PWD/ynew \
    ./test/sh/run_all.sh'
```

Result: port, native, native-examples, examples, audit, ycc-units, ycc,
fixpoint, loops, comprehensive, debug, link, pkg, stdin-eof, net, lsp, math,
coverage and std-suites all pass. `test/math` reports **8,404 cases, worst gap
1 ulp, 0 over 1**.

The math IR reductions were additionally verified bit-for-bit against the
pre-change `std/math.y` (a probe over `cbrt`, `sin`/`cos`/`tan` at large
arguments, `asin`/`acos`, `rem_pio2`, `prod_err` and `fvariance`, compared as
IEEE-754 bit patterns — identical).

`make corpus-diff` between the pre-change reference and the new compiler:
**548 programs, 0 compile to different code, 0 compile or behave differently**
— the `pe_no_abs` guard is output-neutral. `make bench` scored 97.79, which is
inside this machine's noise band (load average ~4.6 from other users; the
branch's own notes record identical builds scoring 98.5–101.5), and the
callgrind profile is `+0.0%` on every function because both sides compiled the
benchmarks against the same on-disk `std/math.y`.

---

## 4b. Tooling added in the integration pass

- **`test/sh/cycc-win.sh`** — W1's gate (see §3): `cycc.exe` under wine must
  compile every fixture to the same bytes, with the same diagnostics and the
  same `-S` listing, as Linux `cycc`. 532 of 535 corpus files agree; the 11
  meta cases are the unported M1 runner.
- **`src/tools/ytest/`** (`make ytest` → `./ytest`) — a test and metrics
  runner written in Y. `./ytest suites` times each `test/sh` suite (all 19 in
  98.8 s here, 0 failures); `./ytest coverage` builds a `gcc --coverage` C
  copy, runs a corpus through it and reports **gcov line coverage** per source
  file — **68.0%, 15,870/23,332 lines**, with `elf` 99.6%, `dwarf` 97.3%,
  `pe` 94.9%, `labels` 100% at the top and `pkg` 26%, `ycc` 30% at the bottom
  (the corpus has no full `ycc build` project and few driver errors);
  `./ytest report` writes `ytest-report.md`. It uses the `popen`/`pread`/
  `pclose` API this pass added — the tool is the feature's first customer.
  Coverage is of `src/c`, the 1:1 twin of `src/y`, so the per-file numbers are
  the compiler's with the documented caveat that `yv.c` and the CLI shims have
  no Y twin.
- **`ycc run FILE -- ARG...`** — the program's own argv, so a test can drive
  arguments without the driver reading them as its own flags.
- **`ycc run` is NOT faster than compile-then-run, measured.** The objective
  asked to switch the suites to it; three runs each, `ycc run FILE` vs
  `ycc FILE -o /tmp/b && /tmp/b`: t45_fib 3 vs 3 ms, t204_std_json 50 vs 51 ms,
  t300_math_int 51 vs 48 ms. The compile dominates and `run` still compiles;
  it saves the ELF write and the `exec`, about a millisecond of ~15. So the
  suites were NOT switched — the speedups that exist are `run_all.sh -j`'s
  sharding and the std pack. `ycc run` was kept for what it does buy: no
  output file, and (with `--`) a program argv.

## 5. Environment notes (gotchas worth keeping)

- **`/tmp` holds files owned by another user.** This checkout's `/tmp` carries
  leftovers from the other worktrees (`/tmp/ynative_test.txt`,
  `/tmp/t199_sgr.txt`, `/tmp/yfp_err`, `/tmp/opencode/…`) owned by `yun` with
  the sticky bit set, so they cannot be deleted or overwritten. `t10_filewrite`,
  `t20_files_argv`, `t199_std_tui`, the fixpoint suite and the LSP fixtures all
  fail on the permission error rather than on a compiler defect. Running the
  suite inside `unshare -rm` with a fresh `tmpfs` on `/tmp` is the workaround,
  and it is what produced the green result above.
- **`refs/` is gitignored and was missing here.** It is not disposable (see
  `AGENTS.md`); it was re-blessed from the merged tree, and the original
  reference for this base is not recoverable from this clone.
- **Rebless timing, measured.** On this 4-CPU host `make rebless` is ~20 s once
  `cycc` exists: `cycc` compiling `ycc.y` 1.48 s, the Y build 0.43 s, the pack
  0.01 s, and the port suite 17.3 s (8 shards, 4 at a time). It looked slow
  earlier only because the host reported one CPU then and the shards serialized
  (~3 min). A *cold* rebless adds gcc rebuilding `cycc` (~40 s). The port suite
  is the cost, and `make check` has usually run it already; that is the one
  place a future change could stop repeating work, and it would need check to
  leave a validated artifact behind rather than re-run the fixtures.
- Three `-Wextra` unused-parameter warnings come from `meta-win`'s C code
  (`asm.c`'s `pe_prologue_push`, `pe.c`'s `pe_bss_from_ro`). They predate the
  merge and do not fail any gate; the Y twins declare the same unused
  parameters, so they were left alone rather than diverge the two copies.
