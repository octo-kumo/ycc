# What would improve ycc next

Written after a round of measured work (maps, string builder, emitter peepholes,
lexer, lint, tags). Each item says what was measured and what it would buy. The
goal is the language's: short, intuitive, safe, fast.

## Fast (the compiler, and what it emits)

- **Inline small leaf defs.** Compiling `bench/y/tmath.y` spends ~20% of its
  instructions in `isalpha`, `isspace`, `tclamp`, `is_op`, `is_punct`: one-line
  defs called per character or token. An inliner for a def whose body is a
  single expression of its parameters would remove the call, the pushes and the
  frame. It helps every Y program, not only the compiler.
- **Operator and declaration kinds are still strings.** Token types (`Tok.t`)
  and environment kinds (`SK`) are numbers now. `Bin.op`, `Un.op` and
  `Decl.kind` ("let"/"const"/"def") are not: ~230 `op == "+"` sites and ~70
  `kind == "def"` sites, and `y_str_eq` is still ~9% of a small compile. Same
  recipe: a table in `tags.y`, change the field type, let the checker list the
  sites (the C twin has no checker, so port from the Y diff).
- **`is_op`/`is_punct` compare the token's text on every peek.** The lexer
  already knows which operator it read; carry an id in `Tok` and compare ids.
- **`push mem` / `push imm` forms.** 28,000 sites in ycc's output are
  `mov X, %rax; push %rax`. A form is two table rows and an encoder arm; the
  care is liveness: only a push whose next instruction writes `%rax` may skip
  the load (every argument but the last, the left of a binary operator). An
  attempt was backed out unfinished; the plan above is the safe version.
- **The C twin has no maps**, so the compiler's own source cannot use `{K => V}`
  (it uses bucketed arrays, `NameIx`, `words_seen`'s hash table). A map in the
  value model (`yv.c`) would let the compiler use the language's own feature.

## Safe

- **The C copy has no `--fix`**: `lint.c` now emits every warning `lint.y`
  does (the port gate compares them at levels 0, 1 and 2), but the fixer
  (`fx_*`, `lint_fix`, `ycc --fix`) exists only in Y. It never touches emitted
  bytes, so the gate cannot see a drift there; a port would need `fix.y`'s text
  rewrites as well.
- **`-> void` accepts a body that has a value** and the value is still returned
  to callers (`lint_compound_op` was declared void and used as a predicate for
  years). Either make `-> void` discard, or warn on a void def whose last
  expression has a non-void type that a caller reads.
- **Unused `import`** is not reported; imports are spliced as text before any
  AST exists, so the resolver needs a diagnostic channel.
- **`match o { T c => .., none => .. }`** on an option still errors (`none` is
  read as a parameter name). `if let T c = o` works now.

## Short, intuitive

- `0 - n` is common in the compiler's own source (the new level-2 rule counts
  ~100). If `-1` has a parsing hazard somewhere, fix the parser; if not, the
  habit goes.
- Maps are O(1) now for `str`/`long` keys; `byte`/`bool`/`float` keys still
  scan. Documented in `07-references.tex`.

## Test infrastructure

- `test_pkg.sh` (974 lines) and `test_comprehensive.sh` (601) are the largest
  and the least shared with `lib.sh`'s helpers; every suite script now uses its
  pass/fail counters.
