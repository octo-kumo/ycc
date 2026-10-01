# audit.md — code-quality and stale-limitation audit

Ten audit agents read every source file in full, section by section, and
verified each claim against the code that would have to support it. This
file records what was found, what was fixed, and what was deliberately
left alone.

**The headline finding.** The codebase carried ~190 comment lines
describing a world that no longer exists: a Y **VM**, a separate **C
backend**, and a **bootstrap parser** with different capabilities from the
Y parser. Since the rewrite to two compilers that are 1:1 copies
(`PORTING.md`), there is no VM, no C backend, and `src/c/parser.c` *is* a
faithful twin of `src/y/parser.y`. Roughly 60 of those comments claimed a
restriction that no longer exists.

**The root of the rot**, found by three agents independently:

> `src/y/parser.y:22-23` claimed `x.y[i]` misparses as `x.(y[i])` and
> cited AGENTS.md as authority — while AGENTS.md says the exact opposite
> ("Dot chains and index chains parse correctly").

~20 files inherited copies of that one wrong note. Proven false by
compiling `o.x[1]`, `deep.a.b[2]`, `f.m.x[0]`, `mk(2).x[1]`,
`len(mk(3).x)`, `!r.ok`, `arr[0].a = 42`, `r.a = …`, `x.y.z = 7` under
**both** compilers and getting byte-identical binaries. The mechanism is
`src/c/parser.c:283-355`, a 1:1 copy of `parser.y:214-286`: one
`parse_postfix` loop that folds `(`, `[`, `.` into a node rebind.

---

## Part 1 — Real defects found and fixed

These are behavioural, not cosmetic. Each was reproduced against the
golden reference before and after.

### 1. `yv.c`: empty-needle `index_of`/`last_index_of` diverged from `rt.y` — FIXED

`ymem_find` returned `from` (so `index_of(s,"")` → `0`) and
`ys_last_index_of` returned `n`. `rt.y`'s `y_str_index`/`y_str_lastidx`
both require `m > 0` and otherwise leave `found = -1` ("An empty needle
never matches"). These are hot paths: `asm.c` calls
`ys_index_of(line, ":")` and `ys_index_of(nm, " ")` on **every assembly
line** it assembles. Both now return `-1`.

### 2. `yv.c`: NUL-bearing strings printed and wrote short — FIXED

A Y `str` may hold NUL bytes (`ys_n`, `from_bytes`), and the native
runtime writes `len(s)`. But `puts_`/`eputs_` used `fputs` and
`write_file` used `strlen`, as did the array/record branches of
`ys_tostring` — all truncate at the first NUL. All four are now
length-based (`fwrite` with `u.s.n`). Latent, because no test corpus
exercises it, but a real divergence between the twins.

### 3. Test harness: five false-PASS paths — FIXED

The most serious class of finding. These made the suite report success
when the two compilers actually disagreed:

- `test_loops.sh` reused a fixed `/tmp/test_bin` and never removed it, so
  **a failed compile ran the previous test's binary**.
- Three "cosmetic diff" allowances (`test_loops.sh`,
  `test_examples.sh`, `test_native_examples.sh`) counted *any* output
  divergence between the compilers as a pass.
- `test_port.sh` treated "rejected by both" as *any* nonzero exit — a
  timeout or crash scored as agreement. Now requires exit 1 from both.
- `run_test "empty program" '' ''` used `grep -qF ''`, which matches any
  output; the case could never fail. Replaced with a `silent_test` that
  asserts empty output *and* exit 0.
- `make test-asan` exported `YCC`, which no suite reads — the sanitized
  build was never actually being exercised. Now exports `CYCC`, and the
  suites honour it.

### 4. Dead code removed — FIXED

- `check_func_value` (types.y/types.c) — the C twin already carried
  `__attribute__((unused))` "def kept 1:1; unused".
- `rt_src()`, `prelude_src()` (rt.y/prelude.y) — dead; `native.y` reads
  the `*_lines()` arrays.
- 12 dead `else { ; }` arms in `enc64.c`, plus `patch_item_isdata` /
  `patch_item_insn` in `asm.c` (the latter had a literal `if (1) {…}
  else {…}`), and a pointless `Yv *b0 = b;` alias in `patch32`.
- A dead store in `prof.y`'s `y_prof_enter`; a `Yv *unused = node;` in
  `native.c`'s `gen_argv` with no Y counterpart (a twin divergence).

### 5. `1:1` twin control flow restored — FIXED

`enc64.c`'s `reg_num` was 40 sequential `else if`s and `fits8` was a
nested ladder, both citing a "joint gate" the checker does not reject;
`asm.c`'s `is_digit_ch`/`is_oct_ch`/`is_alpha_ch` were 10-arm
`ys_eq_lit` chains. All restored to the Y's form — and the predicates
rewritten as the `ys_cmp(...) >= 0 && <= 0` range tests that
`lexer.c:10-24` already uses. `asm.c:101`'s "nested ifs" comment was
also dangling 17 times: it cited an `is_digit_ch` note that did not
exist.

---

## Part 2 — Documentation corrected against the code

- **`src/y/NATIVE.md` was actively wrong** about the array header: it
  claimed `push` may move the array and that header and elements live in
  one block. `arch_x64.y` allocates a **separate** data block and stores a
  pointer at `+16` — which is what several stale comments were reasoning
  from.
- **AGENTS.md**: `push(a, v)` is documented as the way to rebind a grown
  array, but `push` is not a language builtin (the compiler says
  `undefined function 'push'`; arrays grow with `+=`). Corrected, along
  with: empty blocks are legal without a `0;` filler, `if` arms need not
  agree in type, a fixed `[T; N]` cannot grow, captures are shared and
  visible both ways, `[byte]` arrays are packed, elements live in a
  separate block from the header.
- **PORTING.md**: said `src/y/std/*.y` are "read from disk" — `rt.y` and
  `prelude.y` are *embedded in the compiler* as source-line arrays, and
  the C copy compiles them too.
- **`docs/src/*.tex`** (9 chapters) and `README.md`, `lang.md`,
  `src/y/README.md`: prose claims checked against the code.

---

## Part 3 — Proposals: real, but deliberately NOT applied

Each would change emitted code, so AGENTS.md requires
propose → benchmark → decide, plus a `refs/` re-bless. Recorded here
rather than done silently. **Items 1–9, 16–17 and 22 have since been
fixed** — see Part 5.

### Behaviour bugs

1. ~~**`io.read(fd, &buf, n)` segfaults**~~ **FIXED (Part 5).**
2. ~~**`io.exit` shadows the `exit` intrinsic**~~ **FIXED (Part 5).**
3. ~~**`types.y:2530` false diagnostic**~~ **FIXED (Part 5).**
4. ~~**`types.y` unknown-node message**~~ **FIXED (Part 5).**
5. **`types.y:1638-1640`**: a poisoned first array element only adopts
   `tlong`/`tbool`/`tstr`, so `[f(x), 1.5]` keeps a poison element type.
   Related: `is_hash_key` accepts long/byte/bool/float but `map_type_of`
   hard-codes `tstr`, so a non-`str` map key is always a type error. **Open** —
   this changes what programs are accepted.
6. ~~**`names_mentioned` matches substrings inside comments**~~
   **FIXED (Part 5).**
7. **`net.y:75-86` `connect_tcp`** leaks the fd when `connect` fails.
   **FIXED (Part 5).**
8. ~~**`ycc.y:211`**: the `-S` path ignores `write_file`'s result~~
   **FIXED (Part 5).**
9. ~~**`ycc.y:46`**: the `-h` usage line omits `[--prof]`~~ **FIXED (Part 5).**

### Dead code / cleanliness (needs a `refs/` re-bless)

10. **`native.y`**: `flit_num` and `flit_den` are dead defs (proved by
    renaming them and compiling — exit 0). Also `let et = tt.of;` in
    `gen_opassign_arr` and `let unused = node;` in `gen_clock_us`/
    `gen_heap_used`, each wasting 8 bytes of frame per call site. ~12
    read-once binds are redundant. **Measured:** removing a single dead
    `let` shifts frame offsets and breaks the byte gate — dead *defs* are
    tree-shaken, dead *statements* are not. **Still open** — this is the
    frame-size/perf work AGENTS.md wants benched.
11. **Dead emitter arms.** The `and`/`or` arms in `gen_bin_rest` were
    **FIXED (Part 5)**. The `push`/`prepend` arms were **NOT dead** —
    see the corrections below.
12. **`types.y:86-113`**: `teq`'s flag loop is computed and discarded
    (`teq_fields` recomputes it); the comment admits it. **`types.y:584`
    `check_visible`** is a no-op with dummy `unused` locals and `fdepth`
    is never enforced, while `native.y:1507` still claims "the checker
    proved it" about captures. **Still open** — deleting the loops breaks
    the byte gate (measured).
13. **`asm.y`**: `ro_len` written never read; 10 parameters never read;
    `ro += rbytes[j]` where `ro += rbytes` would do; `ycc_assemble` still
    declares an `octal: str` field that is permanently `""`. **Partly
    FIXED (Part 5)**: `ro_len` and the push loop are gone; the unused
    params and the `octal` field remain.
14. **`enc64.y`**: `op_size` (26 call sites — kept, and its comment now
    says `&&` would work), `enc_alu_imm_go` (the body still reads a shape
    via `op_size`, so the split is still meaningful — kept), `r32`/`r8`
    unreferenced. **Still open** for `r32`/`r8` only.
15. **`rename.y:866-891`**: `rn_func_p1…p5` split a `func` node into five
    helpers under a rule ("one field read per body") that no longer
    applies — `func` is annotated with the full shape, so it can be one
    body. **Still open** — changes emitted code.
16. ~~**`io.y`**: `SEEK_SET`, `write_data`, `exit`~~ **FIXED (Part 5).**
17. **`struct.y:281`**: `out += [unpack_one(...)]` allocates a 1-element
    temp array to push one long. **FIXED (Part 5).**
18. **`run_parity` compares output through `$(...)`**, which drops NUL
    bytes — bash warns about it for `test/y/audit/t61_null_byte2.y`, so
    that fixture's byte comparison is weaker than it looks. **Still open.**
19. ~~**`make valgrind` is broken**~~ **FIXED (Part 5).**
20. ~~**`wasm/build.sh`**~~ **FIXED (Part 5)** (rewritten; unverified —
    no emcc here).
21. **`test/y/examples/ysh.y:39`** invokes `ycc --no-io --compile`;
    neither is a driver flag. **Still open** (now tracked in TODO.md).
22. ~~**`AGENTS.md` vs `Makefile`**~~ **FIXED (Part 5).**

### Agent claims that turned out to be WRONG

Three agents independently reported these as dead code. Two were wrong,
and one was right:

- **`push`/`prepend` are NOT dead.** `gen_opassign_arr` builds *synthetic*
  `"push"`/`"prepend"` call nodes (`n_call2("push", …)`) for `arr += v` and
  `arr *= v`, so the dispatch arms and `gen_push`/`gen_prepend` are the
  emitter's own lowering. Deleting them would break every array `+=`.
- **`&fixed-array` was not an emitter bug but a checker hole** — see Part 5.
  My first fix made `gen_addr` load through the header; that was reverted in
  favour of closing the hole, which needed no emitter change at all.
- **`teq`'s discarded loop IS dead** (right, but unfixable under the gate).

### Judged correct and left alone (the "A" verdicts)

Recorded so the next audit does not re-open them:

- The **`bind once` discipline** is still right, but for a different
  reason than the notes claimed: the checker's environment is
  flow-insensitive (one name, one shape — `types.y:1282-1286`). The
  `times[i]` / `r.ok` aliases stay because removing them shifts the
  frame and breaks the byte gate, and the comments now say exactly that.
- The **two `0;` filler loops** in `types.y:86-130` are provably dead,
  but deleting them **breaks `cmp ycc refs/ycc.ref`** (measured).
- **`struct.y:226-229`**'s `let none: [byte] = [];` after `exit(1)` looks
  dead but is *required*: disagreeing arms make the `if` void and
  `out += pack_one(...)` cannot take void. Documented so nobody cleans it.
- **`prof.y`'s 1024-frame clamps** in `y_prof_enter/exit` are live, not
  dead code.
- Verified instruction-by-instruction: the stack ABI (args left→right,
  result in `%rax`, caller cleans), the `y_` bare-label rule, tree
  shaking, `prune_bodies`, every syscall number/flag in `rt.y`,
  `prelude.y` and `net.y`, the `LONG_MIN` digit algorithm, the capture
  box model, slot layout `rbp+16+8*(n-1-k)`, `{len,cap,data}` never
  moving, `L` vs `VmSize` for `o_arrrep`, and the whole `struct.y` byte
  order including sign extension for `get_i8/i16/i32`.

---

## Part 5 — The fixes, part 2 (behaviour, after the audit landed)

Each of these changes what the compiler *does*, so each was verified as a
behaviour change, not as a refactor.

### The `&a`-on-a-fixed-array hole (frame corruption)

`&a` is not a data address. The checker already said so for heap arrays
("cannot take the address of a whole heap array"); a **fixed** array
`[T; N]` slipped through, next to a comment claiming "&a is the address of
the first element (e.g. `read(fd, &buf, n))" — it is not. A slot holds the
`{len,cap,data}` header (fixed arrays are heap blocks too, see
`gen_arrrep_esz`), so `io.read(0, &buf, n)` handed the kernel the frame
slot: the array's own header was overwritten and the next `len(buf)` died
with **SIGSEGV**. `t12_cat.y` only survived because it never re-read the
array after the read.

My first fix made `gen_addr` load through the header — that worked but
changed the emitter for a case the checker should have refused. Reverted in
favour of the smaller, consistent fix: both array kinds now share one
rule and one message, `t12_cat.y` uses `&buf[0]` like every other
address-of in the tree (`net.y`, `rt.y`, `prelude.y`), and
`test/y/native/e34_addr_of_array.y` pins it.

### Comments no longer trigger a prelude splice

`names_mentioned` searched the raw source for `exec`/`readline`/
`clear_eof` — comments included — so a comment containing the word
"executables" spliced the whole fork/execve chunk into the binary (found
during the audit by diffing binaries: `/bin/sh` rodata and ~9 extra uids
in a program that never calls exec). It now strips line and block comments
first, keeping newlines so error line numbers do not shift. Verified both
ways: a comment mentioning `executables` produces the same 8312 bytes as a
plain program, and real `exec`/`readline` calls still splice.

Getting the twins to agree on this took three tries, and the failure modes
are worth recording:

1. The inner line-comment loop set `i = n` to break — which also ended the
   **outer** loop, truncating the source after the first comment. Fixed with
   the codebase's flag idiom.
2. `strip_comments` built an array of characters. Y's `index_of` copes; the C
   twin's `ys_index_of` rejects a non-str and returns `-1`. So *every*
   prelude chunk silently stopped being spliced — the port gate went
   193/201 and `gen2 != gen3` until both twins joined to a string.
3. `join(out, "")` then failed on the Y side, because Y's `out` was a `str`
   and C's was an array. Both now build a `[str]` and join once: O(n), and
   the same value type on both sides.

### Everything else in Part 3 that got fixed

- `io.y`: `SEEK_SET` (no `lseek` wrapper exists), `write_data` (dead —
  executables go out through `write_bytes`), and the `exit` def, which
  shadowed the `exit` intrinsic program-wide and made `--prof` builds lose
  their report (its body is a bare `syscall(60)` with no `gen_exit`
  `y_prof_report` hook). No test used `io.exit`.
- `net.y`: `connect_tcp` closes the socket when `connect` fails.
- `struct.y`: `unpack` appends one long instead of building a 1-element
  temp array.
- `ycc.y`: the `-h` usage line lists `[--prof]`; the `-S` path checks
  `write_file`'s result instead of exiting 0 after a failed write.
- Three false diagnostics in `types.y` (the unpassable-param parenthetical,
  "heap planned: maps, loops, strings ops", "heap planned").
- `asm.y`: the write-only `ro_len` is gone; `ro += it.bytes` uses the
  in-place array append. `native.y`/`enc64`: the dead eager `and`/`or` arms
  in `gen_bin_rest` are gone (`gen_bin` routes `&&`/`||` to `gen_logic`).
- `Makefile`: `YCC_SRCS` was missing `net.y` and `struct.y`; `make valgrind`
  ran `cycc` with no input file (exit 1) and gated on leaks the value model
  can never free — it now memchecks *errors* on a real program.
  `wasm/build.sh` referenced 12 deleted pre-rewrite files; rewritten to the
  current list and marked unverified (no emcc on this machine).

### Deliberately kept, with reasons

- **`op_size` (enc64.y)** — 26 call sites; its comment now says `&&` would
  work and why the gate is still there.
- **`enc_alu_imm_go`** — the body reads a shape through `op_size`, so the
  split still narrows something.
- **`push`/`prepend` (native.y)** — three agents called them dead; they are
  the emitter's own lowering of `arr += v` / `arr *= v`.
- **`teq`'s discarded loop, the vestigial `let` binds, `flit_num`/`flit_den`,
  `rn_func_p1…p5`** — all real, all left open: each changes emitted code, so
  AGENTS.md wants propose → bench → decide. They are tracked in TODO.md.

## Part 6 — How the audit was run, and what it cost

Ten agents (`space-bunny-free`), one git worktree each, disjoint file
sets, required to read every file whole rather than search it.

**Two agents died** (`std`, `parser`, later `docs`) — killed by the OOM
killer, mid-run, because the self-compile peaks at **~31 GB RSS** (two
independent measurements: 32,214,960 kB and 32,212,916 kB) and nine
agents were running `make test` at once. Memory went to 318 MB available
with swap fully consumed; two runaway compilers reached 15.7 GB and
20.2 GB. All their uncommitted work was recovered and verified before
landing.

That memory figure is now documented in `test_fixpoint.sh`'s header so a
bare `Killed` is recognised as the OOM killer rather than a compiler bug.

**A second, input-specific blowup exists**: compiling
`test/y/ycc/test_all_imports.y` (it imports the whole compiler) needs
>6 GB — capped at 6 GB it dies with `out of memory` after 5.8 s,
uncapped it reached 15.7 GB in 11 s. `test_ycc_units.sh` runs it under
`timeout 20`, the compile finishes inside the window, and the suite logs
a **pass** — so `make test` hides a 20 GB spike. Worth fixing: the
`timeout` should be a memory limit, and the fixture's compile probably
wants the O(n²) `concat` path replaced.

**Process notes, recorded because they will bite again:**

- `commit.gpgsign` is **on** in this repo; gpg tries to pop a GUI
  pinentry, times out, and git reports the misleading
  `fatal: failed to write commit object`. Commits must pass
  `--no-gpg-sign` (as `CONTEXT.md` already says).
- Git creates loose objects and packs `0444` by convention. A recursive
  `chmod -R u+w .git` is unnecessary, and a `chmod -R a-w` anywhere can
  silently break commits.
- Locking a worktree read-only does not stop an agent: one hit the
  permission errors, ran `chmod -R u+w .` to "repair" it, and continued.

---

## Verification for every change in this audit

Final state, re-run on a quiet machine after everything landed:

```
make ycc   -> verified: cycc output == refs/ycc.ref == ycc self-compile (byte-identical)
make test  -> ALL SUITES PASSED (port native native-examples examples audit
              ycc-units ycc fixpoint loops comprehensive prof stdin-eof)
              port 201/201 · native 79/79 · native-examples 14/14 · examples 14/14
              audit 65/65 · ycc-units 32/32 (+2 skipped) · ycc 4/4 · fixpoint 4/4
              loops 49/49 · comprehensive 265/265 · prof 8/8 · stdin-eof PASS
```

`port` went 200 → 201 and `native` 78 → 79 because this work added
`test/y/native/e34_addr_of_array.y`.

**`refs/ycc.ref` was re-blessed three times**, only ever for changes that
alter the compiled compiler's bytes, and each time only after the same
three checks:

1. `gen1 == gen2 == gen3` byte-for-byte (the self-hosting fixpoint),
2. the port gate green *before* the re-bless — so the twins agreed on
   every test program with the old ref still in place, which is what
   catches a twin divergence,
3. the new compiler still compiles and runs a real program.

The three: the `rt.y`/`prelude.y`/`prof.y` commit (sources embedded in
the compiler), the checker commit (`&a` on a fixed array + three false
diagnostics), and the `strip_comments` commit. Every other change was
comment-only or C-twin-only and left the golden binary untouched.
