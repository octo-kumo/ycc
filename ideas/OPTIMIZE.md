# Optimizing ycc's output — and ycc itself

A measured plan for four questions:

1. **Can we do computation during compilation?** (fold what is already known at compile time)
2. **Can we optimize the final binary's size?** (yes — 93% of a hello-world binary is padding)
3. **General optimizations to the binary ycc emits** (smaller *and* faster code)
4. **Can ycc's own compiler binary be made smaller?** (yes — ~25%, plus a bigger win from the IR)

The largest single change proposed here is a **structured backend IR** that replaces the
assembly-as-text data path. It is worth doing on its own merits and it also *subsumes*
several of the smaller items, so it is staged last but sized first.

Everything below is measured on this tree with `refs/ycc.ref`. Every number has a
reproduction recipe in the [appendix](#appendix-measuring).

---

## Requirements and constraints

These are repo rules, not preferences. Any change here must satisfy all of them.

| # | Requirement | Where it is enforced |
|---|---|---|
| R1 | **The C twin is 1:1.** `src/c/` mirrors `src/y/` statement for statement; both compilers must emit byte-identical programs. | `PORTING.md`, `make ycc` (`cmp ycc refs/ycc.ref`) |
| R2 | **The fixpoint holds.** Three generations of self-compilation are byte-identical. | `test_fixpoint.sh`, `make ynew` |
| R3 | **`make check` before `make rebless`.** verify (all suites green) → compare (what changed vs `BASE`) → time. | `AGENTS.md`, `test/sh/check.sh` |
| R4 | **No warnings** from `src/y` or `src/y/std`. | `test_fixpoint.sh` |
| R5 | **Deterministic output.** No dependence on hash-map iteration order; `test_port.sh` demands byte-identical binaries from `cycc` and the reference. | `test_port.sh` |
| R6 | **`ycc -g` keeps `.text`/`.rodata` addresses identical to the plain build.** | `test_debug.sh` |
| R7 | **Warnings are not output.** `-w` suppresses them; the binary is the same bytes either way. | `AGENTS.md`, `test_native.sh` |
| R8 | **Every process runs under `ulimit -v 3670016`.** A change that needs more address space is a bug, not a reason to raise the cap. | `AGENTS.md`, `test/sh/capped.sh` |
| R9 | **Bench at the end.** Any change that can affect compile time, output size, or program speed gets `make bench` + `make bench-ir` + `bench/profile.sh`, and the numbers go in the commit message. | `AGENTS.md` |
| R10 | **Y code style** (AGENTS.md, "Y code style"): empty blocks are void, a block's value is its last statement *without* a trailing `;`, postfix binds tighter than unary, recursion uses `self`, no unknown types, records are exact, a `type` alias wherever a record/union is used twice, no unused locals. | `AGENTS.md` |

### Tooling that already exists (no new tooling needed)

- `ycc --time FILE` prints a per-phase table (elapsed ms + heap KB + counters) to stderr,
  including **`asm_bytes`** and **`out_bytes`** — the size ratchet for free.
- `make bench` scores compile time, run time and binary size (SCORE 100 = unchanged;
  within 100 ± 2.5 is noise).
- `make bench-ir` / `bench/profile.sh` give **exact** instruction counts.
- `make corpus-diff FILES="a.y b.y"` lists every program whose exit code, messages or
  binary changed.

---

## Baseline

> **Pinned to `refs/ycc.ref` sha256 `c43509e8…`** (= `./ycc`, blessed 2026-10-04).
> The tree is under active development, so re-measure before trusting any figure here;
> the [appendix](#appendix-measuring) has the recipe for every number.

### Binary size

| artifact | size | breakdown |
|---|---|---|
| `bench/y/hello.y` (`print("hello")`) | **8,312 B** | 129 B `.text`, 333 B `.rodata`, **7,727 B zero padding (93%)** |
| `ycc` | **1,194,578 B** | 1,020,080 ELF + 174,498 std pack |
| `ycc`'s `.text` | 852,283 B | |
| `ycc`'s `.rodata` | 163,172 B | 6,727 string literals + 173 type descriptors |
| `ycc`'s std pack | 174,498 B | gzip -9 → **16,180 B** (10.8× compressible) |
| `ycc -g` extras | 88,311 B | `.symtab` 29,640 · `.strtab` 14,251 · `.debug_line` 44,420 · misc |

Hello world is *representative of the padding problem, not an outlier*: the padding is
`codepad + ropad`, i.e. up to 8 KB for **any** program whose code+rodata fit in two pages.
`lines.y`, `maps.y`, `std_io.y` (12,464 B) and `std_struct.y` (16,560 B) are all in the
same regime.

### ycc's own emitted code (`./ycc -S src/y/ycc.y` → `asm_bytes` 5,091,620, 268,839 lines)

| | |
|---|---|
| instructions | **235,092** in 1,170 functions, 20,052 labels |
| **distinct lines** | **44,429** — 83.5% of lines are exact repeats |
| **distinct mnemonics** | **43** |
| **distinct (mnemonic, operand-shape) forms** | **65** |
| **operand shapes** | **5** — reg · mem · label · imm · rip-label |
| operand slots | 373,963 — reg 232,359 · mem 70,934 · label 30,012 · imm 27,060 · rip-label 12,265 |
| branches | 14,952 |
| stack frames | 837 functions, 44,816 B total, mean 54 B, **max 1,488 B (186 slots)** |

Instruction histogram (top): `mov` 94,504 · `push` 42,939 · `pop` 18,547 · `call` 15,060 ·
`add` 14,212 · `lea` 9,554 · `test` 7,170 · `jmp` 5,741 · `cmp` 5,105 · `jz` 5,046 ·
`xor` 3,531 · `movzbq` 3,223 · `sete` 1,837 · `ret` 1,170.

**42.9% of all instructions are memory traffic, not work:**

| pattern | count | share |
|---|---|---|
| `push %rax` | 35,793 | 15.2% |
| `pop scratch` | 16,489 | 7.0% |
| `mov LOCAL(%rbp), %rax` | 27,151 | 11.5% |
| `mov %rax, LOCAL` | 9,600 | 4.1% |
| binop shuffle `mov %rax,%rcx` | 5,617 | 2.4% |
| `setcc` | 3,076 | 1.3% |
| `movzbq` | 3,080 | 1.3% |
| **subtotal** | **100,806** | **42.9%** |

Most frequent call targets (15,060 calls): `y_alloc` 3,845 · `y_str_cat` 1,636 ·
`y_str_eq` 1,262 · `emit` 923 · `y_arr_push` 732 · `tc_res` 283 · `y_long_tostr` 231.

### Rodata quality

Dead `.rodata`, in **binary** bytes (8-byte `.quad` length + text + NUL):

| program | `.rodata` | dead blocks | dead bytes | dead |
|---|---|---|---|---|
| `bench/y/hello.y` | 333 B | 12 of 14 | 308 B | **92%** |
| `bench/y/maps.y` | 380 B | 17 of 25 | 308 B | **81%** |
| `bench/y/strings.y` | 448 B | 14 of 24 | 308 B | 69% |
| `bench/y/lines.y` | 696 B | 25 of 44 | 398 B | 57% |
| `helloworld.y` | 688 B | 14 of 35 | 308 B | 45% |
| `bench/y/std_struct.y` | 1,064 B | 17 of 69 | 308 B | 29% |
| `ycc.y` | 163,172 B | 100 of 6,968 | — | 1.4% |

**The dead bytes are almost always the same 308 B** — the std runtime's error strings and
format tables, shipped by every program that does not happen to call those functions.
ycc.y is the outlier at 1.4% because it uses nearly all of std.

Duplicate literals (recoverable by interning, in binary bytes):

| | literals | unique texts | recoverable |
|---|---|---|---|
| `ycc.y` | 6,727 | **2,295** | **44.9%** (72,933 B) |
| `std_struct.y` | 61 | 34 | 36.0% |
| `lines.y` | 36 | 26 | 16.2% |
| `strings.y` | 21 | 19 | 4.6% |

The 8-byte length prefix is **33.1%** of literal bytes (53,816 B on ycc.y).
The empty string appears **550 times** in ycc.y.

### Compile time (`./ycc --time src/y/ycc.y`)

| phase | ms | heap |
|---|---|---|
| resolve | 20.0 | 22.0 MB |
| tokenize | 23.7 | 44.8 MB |
| parse | 14.6 | 24.3 MB |
| std (pack) | **0.090** | 0.7 MB |
| std (`--std-src`, hello world) | 4.061 | 7.6 MB |
| strip_ns | 4.8 | 8.3 MB |
| rename | 13.9 | 27.3 MB |
| typecheck | 21.3 | 31.6 MB |
| lint | 13.1 | 14.0 MB |
| **emit_fns** | **78.3** | **147.2 MB** |
| emit_start | 4.3 | 3.4 MB |
| **asm_text** | **14.1** | **46.0 MB** |
| **assemble** | **135.4** | **426.1 MB** |
| ├ a:split | 4.8 | 20.1 MB |
| ├ **a:encode** | **103.8** | **380.1 MB** |
| └ a:link | 26.8 | 25.9 MB |
| l:labmap | 4.6 | 5.1 MB |
| l:patch | 19.8 | 18.7 MB |
| l:elf | 2.4 | 2.0 MB |
| **TOTAL** | **368.8** | **820 MB** |

**201 ms of 369 (55%) and 593 MB of 820 (72%) are spent in the
string → text → re-parse round-trip.** `a:encode` allocates **1,414 bytes per line**
to produce a ~3-byte instruction. See [Part 4](#part-4--the-backend-ir-redesign).

The std pack's value is size-dependent: `std` is 0.090 ms with it vs ~4 ms without —
**~10× on a hello-world compile** (0.429 ms → 4.253 ms total) but only **~1% on ycc.y**.
Compressing the pack is worth it; deleting it is not.

---

## Part 1 — Binary size

Three items, none of which touch codegen semantics. **Requirement: each must leave
`test_debug.sh` and `test_link.sh` green, and each moves every golden binary.**

### A1. Stop writing page padding into the file

**Problem.** `elf_build` (`elf.y:43`) pads `.text` to a page, then pads `.rodata` to a
page, and writes **both pads as real zero bytes**:

```y
let total = code_off + codesz + codepad + rosz + ropad;   // elf.y:66
...
out = push_le64(out, total);   // p_filesz  <- elf.y:93
out = push_le64(out, total);   // p_memsz   <- elf.y:94
```

For `bench/y/hello.y`: 120 (headers) + 129 (code) + **3,967** (codepad) + 336 (rodata
+ trailer) + **3,760** (ropad) = 8,312.

**Why it is unnecessary.** ELF already provides the mechanism: `p_filesz < p_memsz`
means the loader zero-fills the tail. Verified on a live binary by patching the header
and truncating:

```
bench/y/hello.y: 8312 → 4552 bytes, prints "hello", exit 0
```

**Change.**

| file:line | change |
|---|---|
| `elf.y:43` `elf_build` | drop `codepad`/`ropad` from the byte stream and from the padding loops (`elf.y:111-123`); write `p_filesz = <bytes actually written>`, `p_memsz = round_up(filesz, 4096)` |
| `elf.y:100` | `bss_vaddr` must land on the page after the **mapped** image, not the file end |
| `elf.y:39` `elf_bss_from_ro` | recompute for the new layout — it feeds the `.bss` label fixups at `asm.y:1043` |
| `elf.y:142` `elf_debug` | `ro_off` loses `codepad`; `total` becomes the file size, so `symtab_off` / `bss_foff` / `doffs` shift with it |
| `asm.y:1065-1068` | `pad = 0`; the rodata-section label offsets `patch_item` takes become exact |

**Invariants that must survive.**

1. `(p_vaddr − p_offset) % 4096 == 0` for the RW segment. It holds under the new formula
   because `code_off` is 120 or 176, both `< 4096`, so
   `round_up(filesz) − round_up(filesz − code_off)` is either 0 or 4096 and `base` is
   page-aligned.
2. **R6** — `-g` and plain must compute `.text`/`.rodata` addresses from the *same*
   shared helpers (`elf_code_off`). Do not fork the formulas.
3. The kernel maps whole pages, so string helpers may over-read past a trailing NUL. The
   zero-filled tail of the last page covers this exactly as the file padding did — keep
   the comment at `elf.y:46-52` accurate.

**Result.** hello world 8,312 → **585 B**; mapped pages 3 → 1. Also removes a per-byte
`out += 0` loop from every compile.

### A2. Prune unreachable `.rodata`

**Problem.** `link_units` emits **every unit's entire `rodata` array** —
`rodata_pieces(rodpieces, u.rodata)` at `native.y:9641`. String literals are never
filtered, only type descriptors are deduped by label. Measured dead fraction: **29–92% of
`.rodata` bytes**, and the dead part is almost always the *same* 308 B — the std runtime's
error strings and format tables. For `bench/y/hello.y`, 12 of 14 literal blocks belong to
std functions that tree-shaking already removed:

```
"runtime error: slice assignment length mismatch"   ← y_arr_slice, dead
"runtime error: slice assignment out of bounds"     ← y_arr_slice, dead
"runtime error: no match arm matched"               ← y_match_fail, dead
"runtime error: negative shift count"               ← dead
"0123456789abcdef"                                  ← y_bytes_repr, dead
"true" / "false" / "x" / "b" / "n" / "r" / "t"      ← y_str_tolong etc, dead
```

**Why it is nearly free.** The reachability data already exists. `line_refs_b`
(`native.y:818`) already records `lea` operands, so `prune_bodies` (`native.y:1328`)
already collects every `ystr_N` / `ytt_N` that a kept body reaches. Rodata blocks are
label-delimited (`label_at`, `native.y:872`) and self-contained — verified in
`arch_consts` (`arch_x64.y:2068`), where no block references another.

**Change.** After `prune_bodies`, take the union of the kept bodies' refs plus
`const_refs` (`native.y:9629`) and filter each unit's `rodata` through the same predicate
`shake_keep` (`native.y:1018`) uses. **Prune first, then filter**, so A3 composes
without interaction.

**The one hazard.** A live literal not referenced by `lea`. The only non-`lea` reference
form is `mov $A-B` (handled by the `mov` arm of `line_refs_b`, `native.y:826`) and it
exists solely in `arch_consts`, which is already shaken by `shake_refs`. Validate by
diffing every benchmark's `-S` rodata before and after, and by running the full corpus.

**Requirement.** This is the prerequisite for A2's exactness under
[Part 4](#part-4--the-backend-ir-redesign): once operands are structured, `refs` is
structural and this becomes trivially exact rather than heuristic.

**Result.** hello world 585 → **~282 B** (120 headers + 129 code + 25 live rodata +
8 trailer).

### A3. Intern duplicate string literals

**Problem.** `gen_str_const` (`native.y:2867`) takes a fresh `next_uid` per occurrence and
appends a fresh block. There is no interning table anywhere (contrast the type
descriptors, which *are* deduped by `ty_desc_as` / `tyset_add`). ycc.y: 6,727 literals,
2,295 unique texts → **72,933 B recoverable**. The empty string alone is 550 × 9 B.

**Change — at link, not in `gen_str_const`.** Per-unit interning misses the win, because
most duplicates are std-vs-program and std-vs-std. Adding a field to `EmitSt`
(`native.y:1582`) would also mean touching all **21** rebuild sites plus the C twin, for
no benefit.

At link: build a canonical map from the surviving pieces after A2, then rewrite every
`lea <old>(%rip)` in the kept bodies to the canonical label. There is precedent for text
rewriting at link time in `link_locs` (`native.y:9376`). Only `lea` needs rewriting —
`mov $A-B` is `arch_consts`-only.

**Result.** ycc `.rodata` 163,172 → ~90,000 B (**−73 KB, −6% of ycc**).

### A4. Optional: 4-byte string length prefix

The 8-byte prefix is 30.8% of literal bytes (53,776 B on ycc.y). A 4-byte prefix caps
strings at 4 GB and saves ~27 KB, but changes the ABI of `len()` — every `mov (%rax),%rax`
in `arch_x64.y`'s prelude and every length load in the emitter.

**Only after A3**, and only once the literal set is final. Medium risk, low priority.

### A5. Do not link the runtime a program cannot use (done)

**Problem.** Every binary carried the whole collector. `bench/y/hello.y` was **3,069 B**
with 29 `y_gc_*` labels: `print("hello")` allocates nothing, but it linked `y_alloc` --
and the allocator's slow path calls the collector -- because of one **global
initializer**. `src/y/std/rt.y:336` declares `let CLK_TS: [long; 2] = [0; 2];`, and a
fixed array is a heap cell, so the startup initializer called `y_alloc` twice. It was
kept because the dead-global-initializer pass only looked at the *program* unit's cells
and, for a body from the std pack (whose items were not decoded), treated every cell as
read.

**Fix.**
* `link_units` computes cell reads from the **exact IR of every kept body**, decoding a
  packed body's items with `unpack_body` when `all[i]` is empty.
* `dead_cells` covers **every unit's globals**, not just `prog.globals`; a kept prelude
  block's references join the read set.
* `ir_drop_inits` decodes a packed body before dropping its initializer range, and the
  decoded IR is left in `all` for the emission loop.
* The pass moved **before** the prelude shake, which is then re-shaken: the dropped
  range's own references (`y_alloc`, and through it the collector) are the prelude's
  roots.
* `ir_refs_item` records the label of **any** memory operand, not only `lea`: a
  `mov %rsp, y_gc_stack_top(%rip)` store names a cell, and the shake must keep that cell
  or the store is an undefined label at assembly.

**Result.** `bench/y/hello.y` **3,069 → 390 B**, with no allocator call and no collector
label; `json`, `x509` and `tls` unused-import cost `25/94/94 → 0`. A program that does
allocate (`print(1)`, whose number formatting allocates) still carries the collector --
that is the `--gc` work below.

**Gate.** `test/sh/test_treeshake.sh` grew three checks: a hello world may not name the
allocator or a collector block; `test/sh/deadcode.py` counts instructions that cannot
execute (`test/treeshake/deadcode.txt` ratchet); `test/treeshake/shapes.txt` records the
size of the shapes a runtime addition moves first. The same dead-code tool gates the
foreach/raw-loop instruction ratio (`test/treeshake/foreach.y` vs `forloop.y`).

### A6. print(<integer>) formats on the stack (done)

**Problem.** `y_print_long` was `y_print_hstr(tostring(v))` (`std/rt.y:63`), so every
`print(1)` allocated a heap string -- which meant every program that prints a number
linked `y_alloc` and therefore the whole collector. `test/treeshake/minimal.y` was
3,120 B.

**Fix.** The digits already lived in a stack buffer in `y_long_tostr`; the new arch
block `y_os_print_int` (`arch/prelude.s`) formats there and writes digits+newline with
**two writes** (the same two `y_os_write` calls `y_print_hstr` made, so stdout/stderr
interleaving is unchanged). It is reached through the checker's named layer --
`os_call_names()` gained `y_os_print_int` and `std/rt.y`'s `y_print_long` is now
`os_call("y_os_print_int", v)` -- which keeps the documented override: a program's own
`y_print_long` still shadows the runtime's and intercepts `print(int)`
(`test/sh/test_link.sh`, "a program's `y_print_long` replaces the runtime's").

**Result.** `minimal.y` **3,120 → 440 B**, no `y_alloc` and no collector; `t73`'s
`heap_used() > 0` is now `false` (printing no longer allocates) and the fixture says so.
`test/y/native/t379_print_int_no_alloc.y` pins the heap delta across six prints at 0.

---

## Part 2 — Codegen: fewer instructions

Every item here is an emitter change keyed on the AST or the static type — **no new
analysis pass, no register allocator**. Counts are measured on ycc's own 235,092
instructions. **Requirement: R1, R2, R3, R5.**

### B0. A representative target

```y
for i in 0..n { if a[i] == b[i] { found = true } }
```

emits **58 instructions** where ~22 suffice. The loop counter is loaded **three times**;
both arrays are reloaded per iteration; a boolean is built with
`setl %al; movzbq %al,%rax; test %rax,%rax` only to be branched on; the increment is
7 instructions. This is the shape every item below attacks.

### B1. Encoder: memory-destination ALU and unary forms

Two small gaps block the largest win:

- **`enc_alu_imm` (`enc64.y:496`)** — `if (dst.k != K.reg) { err: "alu-imm dst" }`, so
  `add $1, -8(%rbp)` is inexpressible.
- **`enc_unary` (`enc64.y:685`)** — `if (o.k != K.reg) { err: "unary form" }`, so
  `inc -8(%rbp)` is inexpressible.

`enc_alu_imm_go` / `enc_alu_imm_body` are already split out specifically to keep
merged-shape reads out of the body, so adding the `modrm != 3` + SIB/displacement forms is
~15 lines each. `enc_arith` (`enc64.y:468`) is register-only too and will be needed by
later items.

**Requirement.** Purely additive: `make corpus-diff` must be **empty** after this commit.

**Risk:** low. **Effort:** small.

### B2. `x op= imm` and `x++` fast path — 4.9%

`gen_opassign_arith` (`native.y:7029`) and `gen_incdec` (`native.y:6984`) desugar to a
**synthetic AST** — `{ let y_tNv = x + 1; x = y_tNv; y_tNv }` — emitting 7 instructions and
burning a permanent frame slot where `addq $1, -8(%rbp)` is 1:

```
mov -16(%rbp), %rax ; push %rax ; mov $1, %rax ; mov %rax, %rcx ; pop %rax
add %rcx, %rax ; mov %rax, y_tNv(%rbp)        <- y_tNv is a permanent slot
```

`place_read_id` / `place_bind_id` (`native.y:7049`) already special-case a plain
identifier, and the comment there records that re-reading a variable has no side effects.

**Measured: 1,934 sites in ycc's own code**, of which 638 are exactly `x++`-shaped. Saving ~6 instructions each → **~11,450 instructions (4.9%)**.

**Fast path.** `tgt.k == K.id` and `infer(tgt)` is `long`/`int`/`byte` → emit the ALU op
directly into the local's `%rbp` slot; `x++`/`x--` → `inc`/`dec` on the slot. Guard the
immediate range for the 32-bit forms.

**Requirements.**
- The target must still be evaluated exactly once (an id read qualifies; an index or field
  target does not — those keep the desugar).
- Captured variables must still go through `box_bound`.
- Globals, index and field targets keep the existing path.

**Risk:** medium. **Effort:** small.

### B3. Constant folding and dead-arm elimination — 3.6%

`gen_typeof` (`native.y:4723`) already resolves to a `.rodata` pointer, so
`typeof(e) == "long"` compares **two compile-time constants** — yet it emits a full
`y_str_eq` call. ycc's own output has **1,262 `y_str_eq` calls, 304 with two literal
operands**; the rest are `typeof` dispatch chains (`if typeof(e)=="long" … else if
typeof(e)=="str" …`) where *every* arm is a call on constants.

**Change.** Introduce a compile-time string-value notion in the emitter (`gen_str_const`
already has the literal `s` in hand at `native.y:2867`) and fold in `gen_bin_rest`'s
string `==` / `!=` arm. Then, because the condition is constant, **drop the untaken arm
entirely** — that is where the multiplier is.

Also fold: `len(lit)`, `lit + lit`, `lit[i]`, `lit == lit`, `y_long_tostr(const)`.

**Result.** ~1,200 calls and **~8,400 instructions (3.6%)** removed; 7.8% of all calls.

**Requirements.**
- **R7/R4:** must not perturb the types `types.y` and `lint.y` see, or warning output
  changes and every suite that compares warnings breaks.
- **R5:** folding must be a pure function of the AST — no dependence on emission order.
- `make corpus-diff` must list **only** size changes; any behaviour difference is a bug.

**Risk:** medium-high — the highest-risk item in Part 2, because a wrong fold changes
*behaviour*, not just size. **Effort:** medium.

### B4. Boolean into branch — 2.6%

**3,036 sites** emit `setcc; movzbq %al,%rax; test %rax,%rax; jcc` — four instructions to
branch on a value that is only tested.

**Change.** `gen_if` (`native.y:5033`) and `gen_while` (`native.y:5087`) hold the AST:
when the condition is syntactically a comparison, emit `cmp` + the inverse `jcc`
directly — two instructions. Separately, `if (c) {1} else {0}` in *expression* position
becomes `setne %al; movzbq %al,%rax` — two instructions, no branch, no label.

**Requirement.** Drive the inversion off the operator, **not** by string-matching an
emitted `jcc` mnemonic (which does not exist yet).

**Risk:** low. **Effort:** small.

### B5. Loop value in statement position, and `jmp L; L:` — 0.4%

- **586 loop merge labels** are followed by `xor %eax, %eax` and then *immediately by
  another label* — the value is provably never read. The trailing `xor` is emitted at
  `native.y:5100`, `5124`, `5160`, `5210`. `gen_discard` (`native.y:3288`) already exists
  and is already used for the loop *body*; the loop's own value needs the same treatment.
  (1,233 such labels exist in total; the other 647 are expression-position, where the value
  is live — do not touch them.)
- **420 `jmp L` immediately followed by `L:`** — a jump to the next instruction. Delete it
  at the emitter, where the shape is known.

**Risk:** low. **Effort:** small.

### B6. The `op=` desugar's dead trailing value — 0.5%

**1,173 sites** where a boolean materialization is followed by `mov LOCAL(%rbp), %rax` and
nothing consumes it. `gen_block_as` runs a block's last statement with `gen` rather than
`gen_stmt`, so `block4(bind, d2, asg, n_id(t1+"v"))` (`native.y:7029`) always materialises
the discarded result. Fixed for free by B2 on the id path; worth fixing in
`gen_block_as` for the rest.

**Requirement.** The trailing statement's value *is* live in expression position — this
must be gated on statement context.

**Risk:** low-medium. **Effort:** small.

### Part 2 total

~28,700 instructions (**~12%**) off ycc's own code; ~100 KB off `.text` and ~18 KB off the
std pack (which is ~90% emitted asm text).

---

## Part 3 — Computation during compilation

### C1. Speed up the encoder's data model

`a:encode` is **106.5 ms (28%) and 379 MB** of a 376 ms / 820 MB compile. It allocates
**1,414 bytes per line** because:

- `Operand` (`enc64.y:21`) is a **13-field record** — 8 longs, 3 `str`s and a bool, ~104 B
  — rebuilt per operand by the text parser (373,963 slots × 104 B = **38.9 MB** of
  `Operand`s alone).
- `enc_insn` (`enc64.y:782`) is a 44-arm `mn == "..."` string-comparison ladder.
- It returns `Encoded = { bytes: [byte], fix: [Fixup], err: str }` (`enc64.y:257`) — two
  more array headers plus a `Fixup` record **per instruction**.

This is independent of Part 4 and can be done at any time: encode into a preallocated
buffer with a cursor instead of building a `[byte]` per instruction, and dispatch on a
mnemonic id rather than a string.

### C2. Parallelise `ycc build`

`pkg.y` computes a topological order of the dependency graph but compiles packages
**sequentially** (no `spawn`/`join` anywhere in it). Y has working `spawn`/`join`
(`clone(2)`-based threads), so independent packages can compile in parallel.

**Requirements.**
- **R5:** byte-identical output. Label uniquing (`next_uid`) must not depend on thread
  scheduling — uniquify per unit, then renumber at link in link order.
- **R8:** each thread allocates its own heap through `%fs`; peak memory multiplies.
  `ycc` compiling `ycc.y` already peaks at 820 MB against a 3.5 GiB cap. Gate the worker
  count and measure peak RSS before enabling it by default.

**Risk:** medium-high. **Effort:** medium. **Defer** until A and B have settled — it
optimizes the wrong thing while the back end is 2.3× slower than it needs to be.

### C3. Memoise `infer()` in the emitter

`infer` (`native.y:1699`) re-derives types constantly and dominates `emit_fns` (81 ms).
A memo keyed on node identity would help — but only if node identity is stable, which is
exactly what [Part 4](#part-4--the-backend-ir-redesign) changes. Do it after Part 4.

---

## Part 4 — The backend IR redesign

**This is the largest change proposed here, and the one with the best ratio.** It is worth
doing on its own merits and it subsumes A2's exactness, C1, and the pack items C5/C6.

### The problem, precisely

The emitter formats an instruction into a `str`; `emit_one_fn` (`native.y:8591`) joins
268 K lines into one 5 MB string; `asm.y` **splits it back into lines** and rebuilds
structured data out of it. 201 ms and 593 MB of a 369 ms / 820 MB compile are spent on that
round-trip.

### Why it is feasible

The vocabulary is tiny: **43 mnemonics, 65 (mnemonic, operand-shape) forms, 5 operand
shapes**, and **83.5% of all lines are exact repeats**. A form-indexed encoding is not a
stretch.

### Proposed encoding

One packed `[byte]` buffer per body. Instructions at a fixed stride, **zero records per
instruction**:

```
byte 0      form      index into a 65-entry form table
bytes 1..n  payload   fixed per form: immediates (8B), displacements (4B),
                     register numbers (1B), base/idx/scale (1B each),
                     label ids (4B)
stride      <= 16 bytes, from the form table
```

235,092 × 16 = **3.8 MB in one buffer**, versus 593 MB today. A `[byte]` grows
geometrically in place, so appending is amortized O(1).

The form table entry holds: mnemonic id, operand kinds, payload size, and the **byte
template** for that instruction — so encoding is a `memcpy` of the template plus
REX/SIB fixups at known offsets, written straight into the output buffer with no
intermediate `[byte]`. That replaces `enc_insn`'s 44-arm string ladder with a table index
and retires C1 as a side effect.

**Labels become integers.** `next_loc` currently mints `yL_<fuid>_<n>` as a string per site
(20,052 in ycc's code) and every use is a concatenation. Instead mint a `long` per body,
with an `id → name` side table kept only for `-S`, `-g` symbols and diagnostics.

### The `-S` renderer — the `-> str` function

Walk the buffer; for each form, look up the mnemonic name and format the operands from
the table. ~60 lines, run **only** under `-S`. It must reproduce today's formatting
**byte for byte** (`bench/compare.sh` diffs assembly, and users diff it by hand), including
the 4-space indent and the fact that `emit` (`native.y:1591`) appends one array element
per line, so each line is its own line.

### What this deletes outright

Because operands are structured, references become structural:

| deleted | lines | why |
|---|---|---|
| `line_refs_b`, `refs_range`, `text_refs` | `native.y:811`, `853`, `877` | scans text to rediscover which labels a body mentions; `refs` becomes a list of label ids filled in during emission |
| `body_label`, `label_at` | `native.y:872`, `900` | text scanning to find where a body starts |
| `link_locs` | `native.y:9376` | `split(b, "\n.loc ")` per body for `-g`; becomes a field |
| the text lexer in `asm.y` | `tok_at_b`, `parse_operand`, `is_id_b`, `skip_sp`, `asm_assemble_line` | no text to lex |

This makes **A2 exact** rather than heuristic, and makes `-g` line info a field rather
than a text marker.

### Effect on the std pack

The pack's ~6,700 instructions go from 26 B/instruction of text to ~10 B/instruction of
IR, and the label-name lists (`refs`, `labels` — 720 B for `prelude` alone) become id
tables. **174,498 B → ~70 KB (−9% of ycc)**, which **retires E4 and E5 below** — no inflate
implementation, no pack-version churn beyond what the IR already needs.

### Risks

1. **Largest change in the repo's history.** ~10,425 lines of emitter, 1,363 of assembler,
   948 of encoder — each mirrored in `src/c/`. The emitter edit is mechanical (replace
   `emit(st, "    mov " + …)` with `emit_insn(st, F_MOV_R_M, op_rax, mem_disp_base(off, RBP))`)
   but it touches every arm.
2. **Two frontends.** `arch_prelude_lines` (`arch_x64.y:89`) is 1,700 lines of hand-written
   asm **text**. Either the assembler keeps a text path alongside the IR path, or the
   prelude is converted to IR too. The latter is cleaner and mechanical (it is a fixed list
   of strings) but is another chunk of work. **Decide this at Stage 2 kickoff.**
3. **`-S` must stay byte-identical** — see above.
4. **Error paths change shape.** `asm.y:625` treats an unrecognised line as "a loud error
   with a line number — never a silent miscompile". A structured IR makes that class
   impossible (a genuine improvement), but tests asserting assembler diagnostics need
   re-expressing. `test/fuzz/fuzz.sh` still works because it mutates *source*.
5. **Every binary's bytes move**, so the first `make check` re-blesses everything. The
   fixpoint gate (R2) is the real safety net here, and it is a good one.

### Staging

Do **not** do this as one commit.

| stage | content | must hold |
|---|---|---|
| **1** | **Labels as integers.** `next_loc`, `env_find`, `link_units`, `prune_bodies`. Deletes `body_label`/`label_at`; prepares structural refs. Also fixes a latent sharp edge: `line_refs_b`'s `mov` arm must reconstruct `mov $A-B` from a text scan, which integer labels make exact. | **Zero byte changes.** `make check` must report an empty diff. Smallest, riskiest seam — a good pilot. |
| **2** | **Operand IR and direct encode.** Where the 201 ms → ~70 ms and 593 MB → ~65 MB land. Retires the text lexer, `line_refs_b`, `link_locs`. Adds the `-S` renderer. Decide the prelude question here. | `make check` green; `make bench` shows the compile-time and memory win. |
| **3** | **Pack in IR form.** Retires C5/C6. | `test_link.sh` and `test_fixpoint.sh` green; `make corpus-diff` empty. |

### One thing *not* worth doing first

I checked whether **line interning** would be a cheap first step. It is not worth much on
its own: interning collapses 268,839 line strings to 44,429 objects, but that is ~10 MB
against an 820 MB peak, and it does not shrink the joined text or the pack at all (the
joined text is byte-identical, so binaries and the pack do not move). It would be a
zero-risk rehearsal of the `emit` plumbing, not a win. Skip it; go straight at the operand
IR.

---

## Part 5 — Structural changes

| # | item | payoff | risk | notes |
|---|---|---|---|---|
| **E1** | **Short-jump relaxation.** `enc_jmp` (`enc64.y:704`) is always `E9 rel32` (5 B); `enc_jcc` (`enc64.y:727`) always `0F 8x rel32` (6 B). **14,952 branches** in ycc's code. | **~30 KB, 3.5% of `.text`** | **high** | The blocker is the one-pass-length design (`asm.y:9-11`). Fix: let pass 1 request the **short** form optimistically, then iterate — any branch whose target does not fit grows to the long form, recompute offsets, repeat until stable. Growing is monotone in the "does not fit" direction, so it converges; bound rounds by the branch count. **Do this last** — it interacts with every item that changes code size. |
| **E2** | **Frame-slot reuse by lexical scope.** `EmitSt.slots` (`native.y:1582`) is a monotonic counter that never returns a slot; **one ycc function has a 186-slot / 1,488-byte frame**. Save/restore `st.slots` around block boundaries. | **max stack depth**, not size | medium-high | Every `box_bound` site (`native.y:5165`, `5183`) must be audited first: a captured variable's heap cell outlives the scope, so freeing its slot is unsound. Prerequisite for the deferred copy-propagation work. |
| **E3** | **Loop-invariant hoisting.** `gen_foreach` (`native.y:5129`) takes **three** frame slots `[x][arr][i]` and re-reads `len(arr)` every iteration; `gen_forrange` (`native.y:5093`) takes two. Across **537 generated loops**: 5,727 slot loads, **1,312 beyond** what a counter needs. | ~1,300 instructions | medium | Do together with B5's loop-slot handling, and prefer the `inc -8(%rbp)` form B1 unlocks (3-instruction step → 1). Must not hoist past anything that can change the length (`y_arr_push` in the body). |
| **E4** | **Compress the std pack.** gzip -9: 174,498 → **16,180 B**. | **−158 KB, −13% of ycc** | medium | Needs an inflate implementation in Y (~250 lines), applied at `self_pack` (`ycc.y:132`) and `std_units` (`native.y:8962`). **Superseded by Part 4 Stage 3** (~65 KB with no new code) — only do this if Stage 3 is abandoned. Budget ~1–3 ms/compile against the 0.429 ms hello-world floor. |
| **E5** | **Denser pack text.** `emit` output is indented 4 spaces (~6,700 × 4 = 27 KB of the pack). | −26 to −50 KB | medium | Requires a `pack_version` bump (`native.y:9666`, currently `ycc-std-pack 5`); touches `test_link.sh`, `test_fixpoint.sh`, and the object cache in `pkg.y`. **Superseded by Part 4 Stage 3.** |
| **E6** | **Tail calls beyond direct self-recursion.** `is_self_call` (`native.y:5188`) only matches `self` or the function's own label. Mutual recursion, tail calls to other functions, and calls through closures all grow the stack per iteration. | runtime + max stack | medium | Needs a general tail-call decision (frame shapes differ per callee). Part of the deferred register-allocation territory. |
| **E7** | **Inline tiny functions.** Every Y-level function is `call` + `add $N,%rsp` (`gen_direct`, `native.y:4982`), even `y_heap_used` (8 instructions, `arch_x64.y:498`). | runtime | medium | Requires a cost model and a call-site budget. |

---

## Deferred — out of scope, with the map

Deliberately excluded. Recorded so a later pass has the entry points and the measured
headroom.

| item | headroom | prerequisite |
|---|---|---|
| `x op= v` with a register RHS → `add %rcx, off(%rbp)` | part of B2's 1,934 sites | `enc_arith` memory source (`enc64.y:468`) |
| Redundant reload of the same local | 27,151 local loads (11.5%) | E2's scope model |
| CSE of repeated subexpressions (`a[i] + a[i]` emits the base, the bounds check and the load twice) | — | a value-identity map on the AST |
| Operand forwarding into ALU ops | the `push; mov %rax,%rcx; pop` shuffle, 5,617 sites | B1's `enc_arith` |
| Text peephole over `st.out` | insertion point `emit_one_fn` (`native.y:8591`) → `asm_link` (`asm.y:1019`) | must cope with label-prefixed lines |
| **Register allocation / colouring** | **~100,806 instructions (42.9%) is memory traffic** | `NATIVE.md:202` lists it as future work. Would also need `%rbx`/`%r12`–`%r15`, which generated code never uses today |
| General tail calls | E6 | frame-shape analysis |
| `ycc build` parallelism | C2 | R5 determinism work |

---

## Landing order

Each line is a separate `make check` → `make rebless`.

| # | item | why here |
|---|---|---|
| 1 | **B1** encoder memory forms | additive, zero output change — validates the encoder plumbing |
| 2 | **A1** ELF padding | biggest single size win (93% → ~7% overhead on small binaries), no coupling to the emitter |
| 3 | **A2** rodata pruning | reuses `prune_bodies`; unblocks A3 |
| 4 | **A3** literal interning | needs A2's surviving set |
| 5 | **B4**, **B5**, **B6** boolean/loop/dead-value | small, independent, each verifiable |
| 6 | **B2** `op=`/`++` fast path | the largest instruction win; needs B1 |
| 7 | **B3** constant folding | highest risk; do with the most suite time available |
| 8 | **E3** loop hoisting | with B5's slot handling; uses B1's `inc` |
| 9 | **C1** encoder data model | independent; can be pulled forward at any time |
| 10 | **E1** jump relaxation | **last of the incremental items** — it interacts with every size change above |
| 11 | **Part 4 Stage 1** labels as integers | must produce a zero diff; pilot for the big change |
| 12 | **Part 4 Stage 2** operand IR | the ~1.9x compile-time / ~9x back-end-memory win |
| 13 | **Part 4 Stage 3** pack in IR | retires E4/E5 |
| 14 | **E2** frame-slot reuse | after E2's `box_bound` audit |
| 15 | **C2** `ycc build` parallelism | only once the back end is fast enough to matter |

### Gates per step

1. `make check` — verify (generations 2 and 3 byte-identical, `cycc` builds `NEW` byte for
   byte, **all suites green**), then compare, then time.
2. `make corpus-diff` — empty except for intended byte/size changes. Every behaviour
   difference listed must be accounted for.
3. `make bench` — compile time, run time, binary size. `make bench-ir` and
   `bench/profile.sh` for exact instruction counts (the ground truth for Part 2's claims).
4. `ycc --time` before/after — `asm_bytes` and `out_bytes` are the size ratchet.
5. `make rebless` — every item moves `refs/ycc.ref`.

### Headline numbers to track

| | now | after A | after B | after C/E | after Part 4 |
|---|---|---|---|---|---|
| `bench/y/hello.y` | 8,312 B | ~282 B | ~265 B | ~245 B | ~245 B |
| `ycc` | 1,194,578 B | ~1,110,000 | ~995,000 | ~820,000 | ~820,000 |
| ycc's own instructions | 235,092 | 235,092 | ~206,400 | ~200,000 | — |
| compile time (ycc.y) | 369 ms | 369 ms | ~353 ms | ~343 ms | **~185 ms** |
| peak heap (ycc.y) | 820 MB | 820 MB | ~810 MB | ~800 MB | **~250 MB** |

These are estimates. Each item needs `make bench` to confirm, and the commit message
carries the real numbers (R9).

---

## Risk register

| risk | items | mitigation |
|---|---|---|
| A wrong constant fold changes program behaviour | B3 | `make corpus-diff` must show size-only changes; run the full suite twice |
| Warning output changes (types feeding `lint.y`) | B3, B4 | `test_native.sh` checks every `expect-warning`; R7 |
| Assembler diagnostics change shape | Part 4 | update the affected fixtures explicitly; note them in the commit |
| `-S` output drifts | Part 4 | diff `ycc -S` output for the whole corpus before/after |
| Fixpoint breaks | all | R2 is checked by `make ynew` on every `make check` |
| C twin diverges | all | R1 is checked by `make ycc`; keep changes mechanical |
| Memory cap (R8) | Part 4, C2 | measure peak RSS; `ycc` on `ycc.y` is already 820 MB of 3.5 GiB |
| The IR change is too large to review | Part 4 | the three stages, each with its own gate; Stage 1 must be a zero diff |
| E1's iteration does not converge | E1 | it is monotone; assert a round cap and fall back to all-long, which is today's behaviour |

---

## Appendix: measuring

Every number above, reproducible.

```sh
# binary size and section layout (no section headers without -g, so use -g to read them)
./ycc -o /tmp/h bench/y/hello.y && stat -c%s /tmp/h && readelf -l -W /tmp/h
./ycc -o /tmp/hg -g bench/y/hello.y && readelf -S -W /tmp/hg

# the padding win, without touching the compiler: patch p_filesz and truncate
python3 - <<'EOF'
import struct
d = bytearray(open('/tmp/h','rb').read())
phoff = struct.unpack_from('<Q', d, 32)[0]
struct.pack_into('<Q', d, phoff+32, 4552)   # p_filesz = last real byte
struct.pack_into('<Q', d, phoff+40, 8312)   # p_memsz  unchanged
open('/tmp/hp','wb').write(bytes(d[:4552]))
EOF
chmod 755 /tmp/hp && /tmp/hp        # prints "hello", exit 0

# compile phases, heap, asm_bytes and out_bytes
./ycc --time src/y/ycc.y -o /tmp/y
./ycc --time --std-src bench/y/hello.y -o /tmp/h     # the pack's value

# instruction histogram and the peephole-killable patterns
./ycc -S src/y/ycc.y > /tmp/ycc.s
awk 'BEGIN{f=0} /^\.section \.rodata/{f=1} f==0 && (/^    [a-z]/ || /^[A-Za-z_$][A-Za-z0-9_$.]*:/)' /tmp/ycc.s \
  | sed 's/^ *//' | sort | uniq -c | sort -rn | head -30

# frame sizes
grep -o '^    sub \$[0-9]*, %rsp' /tmp/ycc.s | grep -o '[0-9]*' | sort -n | uniq -c

# dead .rodata (a kept body only reaches what it `lea`s).
# Measure in BINARY bytes, not text bytes: a block is 8 (.quad length) + len + 1 (NUL).
./ycc -S bench/y/hello.y > /tmp/h.s
awk '/^\.section \.rodata/{f=1} f' /tmp/h.s > /tmp/ro.s
grep -o 'lea y[a-z]*_[A-Za-z0-9_$.]*(%rip)' /tmp/h.s | sed 's/lea //; s/(%rip)//' | sort -u > /tmp/refs.txt
grep -o '^y\(str\|tt\)_[A-Za-z0-9_$.]*:' /tmp/ro.s | tr -d ':' | sort -u > /tmp/lits.txt
comm -23 /tmp/lits.txt /tmp/refs.txt | wc -l          # dead blocks
python3 -c "
import re
refs = set(open('/tmp/refs.txt').read().split())
def bb(b):
    n  = 8 if re.search(r'^\.quad ', b, re.M) else 0
    n += sum(len(s) + 1 for s in re.findall(r'^\.string \"(.*)\"\$', b, re.M))
    n += sum(len(a) for a in re.findall(r'^\.ascii \"(.*)\"\$', b, re.M))
    return n + sum(int(x) for x in re.findall(r'^\.zero (\d+)', b, re.M))
tot = dead = 0
for b in re.split(r'(?m)^(?=ystr_|ytt_)', open('/tmp/ro.s').read()):
    m = re.match(r'(ystr_[A-Za-z0-9_\$.]+|ytt_[A-Za-z0-9_\$.]+):', b)
    if m:
        tot += bb(b)
        if m.group(1) not in refs: dead += bb(b)
print('rodata %d B, dead %d B (%.0f%%)' % (tot, dead, 100.0 * dead / tot))
"                                                  # -> rodata 333 B, dead 308 B (92%)

# the pack
./ycc --std-pack /tmp/ycc.pack && ls -l /tmp/ycc.pack && gzip -9 -c /tmp/ycc.pack | wc -c
```

Benchmark discipline (R9): keep both binaries on the same filesystem — under WSL a binary
run from `/mnt/c` pages through drvfs and measures ~30% slower. A SCORE within 100 ± 2.5 is
no change; a timing row of 40 ms or more agrees to ~8%; shorter rows swing 20%+. Instruction
counts are exact.
