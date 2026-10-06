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
  encoder guard the Windows design claimed but never had, and the two stale
  comments that promised things nobody had built.
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
  sites still in `std`: `tui.y` 29, `net.y` 21, `fs.y` 11, `http.y` 2,
  `tls.y` 2, `crypto.y` 1 (getrandom). Each needs a Linux half in
  `arch/prelude.s` and a Windows half in `wsys.s`; the NT halves for
  directory/stat I/O and `std/net` are the large ones.

### Yet to do

| item | why it is open |
|---|---|
| **`B2`** the rest of the named-syscall layer | the work above; needs NT bodies for `newfstatat`, `getdents64`, `mkdirat`, `renameat`, `unlinkat`, `fchmodat`, `getcwd`/`chdir`, console `readline`, `exec`, threads/`fork`, net, crypto |
| **`W1`** `cycc.exe` under mingw-w64 | **DONE for non-meta programs.** `x86_64-w64-mingw32-gcc` is installed, `make cycc.exe` builds from the same `src/c`, and `test/sh/cycc-win.sh` reports 532 same / 11 different over the corpus. All 11 are the meta fixtures: their M1 runner forks and maps a memfd, which is the NT `fork`/`mmap` work below. |
| **`W5`** the std split | largely superseded by `B1`'s named layer for the packed units; the rest is `B2` |
| **`W6`** the Windows harness | job-object memory cap (`ulimit -v` has no Windows equivalent), a PE `test_debug.sh` branch, `llvm-*` tool swap |
| **`w_self_test_lines()`** | the startup probe that checks one `Nt*` call per class. It is **not implemented** (the comment now says so instead of claiming otherwise); the syscall numbers remain pinned to one ntdll sample with nothing verifying them at runtime |
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
