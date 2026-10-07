# Lint rules

What `lint.y` warns about. A warning never changes the program: the same
bytes are emitted with or without it. Every rewrite below is equivalent to
the code it replaces — where it is not, the `Skip` line says so.

Each rule is written as:

- **Instead** — the longer code, as it appears in the tree.
- **Write** — what to say instead (the warning text names it).
- **Detect** — the node shape that matches, in the checker's terms:
  `Assign`, `Bin`, `Call`, `If`, `While`, `Slice`, `Decl`, ... .
- **Skip** — the conditions under which the rewrite would be wrong, so the
  rule must stay quiet. A rule with no `Skip` line is unconditional.

Rules marked **(needs `in`)** depend on the `in` operator of section 5,
which does not exist yet.

The shortening rules are off by default and reported by `ycc -W 2`
(level 1 is the dropped-value checks). The correctness rules of section 6
are the default level 0.

Implemented so far (level 2): 1.1-1.5, 1.9 (2.7 is its condition form),
2.1-2.4, 2.6, 2.8, 3.1. The rest is the plan.

## 1. Expressions

### 1.1 Compound assignment
- **Instead** `x = x + e`, and `- * / % & | ^ << >> >>>`
- **Write** `x += e` (the same operator).
- **Detect** `Assign` whose `v` is a `Bin` with op in the set and whose
  left operand is an `id` spelled exactly like `Assign.name`.
- **Skip** `x` is an array, record or map: `+=` writes in place, `+` makes
  a new value, and an alias sees the difference. Scalars only (number,
  string, bool) — the `scal` flag `lint_note` already records.

### 1.2 Increment and decrement
- **Instead** `x = x + 1` / `x = x - 1`
- **Write** `x++` / `x--`.
- **Detect** 1.1 with the right operand the literal `1`.
- **Skip** nothing: any type that accepts `x = x + 1` accepts `x++`.
- Also `x += 1` → `x++`, `x -= 1` → `x--` (an `OpAssign`).

### 1.3 `byte_at(s, i)` → `s[i]`
- **Instead** `byte_at(s, i)`
- **Write** `s[i]`.
- **Detect** a `Call` of the builtin `byte_at` with two arguments.
- **Skip** the unit declares its own `byte_at` (the builtin is replaced).

### 1.4 One-element slice
- **Instead** `s[E:E + 1]` (also `s[E:1 + E]`, any expression `E`)
- **Write** `s[E]` for a `str` — one byte, no string allocated; compare it
  with a char literal `'c'`. For an array it is `[a[E]]`.
- **Detect** a `Slice` whose `hi` is a `Bin` `+` of one operand that is
  syntactically equal to `lo` and the literal `1`.
- **Skip** `E` is not pure (a call): the slice evaluates it twice and the
  index once. Also skip when the receiver's type is unknown and the result
  is used where the 1-char *string* is wanted — the rewrite yields a byte,
  so comparisons must switch to char literals (`'c'`, not `"c"`).

### 1.5 `ord` of a one-element slice
- **Instead** `ord(s[E:E + 1])`
- **Write** `s[E]`.
- **Detect** 1.4 with the `Slice` as the only argument of `ord`.
- **Skip** as 1.4.

### 1.6 Equality chains
- **Instead** `x == A || x == B || x == C || ...` (3 or more), **(needs `in`)**
- **Write** `x in [A, B, C]` for an array, `x in "ABC"` for bytes or
  one-char strings.
- **Detect** flatten the `||` tree; every leaf is `Bin` `==` with the same
  left expression and a literal right; all literals have one type. Cap the
  chain at the leaves — a mixed `==`/`&&` nest is not this shape.
- **Skip** fewer than 3 leaves (not shorter); the left expression is not
  pure (the chain evaluates it per leaf, `in` once); the leaves are not
  disjoint (the answer is the same but the rewrite reads as if they were).
- The `!=` form is the same with `!(x in ...)`.

### 1.7 Consecutive literals
- **Instead** `c == '0' || c == '1' || ... || c == '9'`
- **Write** `c >= '0' && c <= '9'`.
- **Detect** 1.6 whose literals sort into a contiguous run (each one is the
  previous plus 1).
- **Skip** the literals have gaps (use 1.6 instead); the type is a float
  (a run of float literals is a coincidence, not a range).

### 1.8 If-chain that is a set test
- **Instead** `if (c == '0') { true } else if (c == '1') { true } ... else { false }`
  (the `isdigitch` shape; every arm `true`, or every arm `false`)
- **Write** `c in "0123456789"` **(needs `in`)**, or the range of 1.7 when
  the literals are consecutive.
- **Detect** an `If`/`else`-chain whose condition is `Bin` `==` against a
  literal, whose arms are all the same bool literal, and whose final `else`
  is that bool's opposite or the last comparison.
- **Skip** an arm does anything else; the tested expression is not pure.

### 1.9 Boolean literal comparison
- **Instead** `x == true`, `x != true`, `x == false`, `x != false`
- **Write** `x`, `!x`, `!x`, `x`.
- **Detect** a `Bin` `==`/`!=` with one side a bool literal.
- **Skip** nothing; the checker only accepts a bool here.

## 2. Statements and control flow

### 2.1 Empty `if` arm
- **Instead** `if (c) { } else { B }` → `if (!c) { B }`;
  `if (c) { A } else { }` → `if (c) { A }`;
  `if (c) { }` → delete it.
- **Write** as above.
- **Detect** `If` whose `then` or `els` is an empty `Block` (comments are
  not in the tree, so a comment-only block is empty), and no `else if`
  chain on the arm being dropped.
- **Skip** the arm being dropped is an `else if`.

### 2.2 Initialise, then assign under a condition
- **Instead** `let x = a; if (c) { x = b; };`
- **Write** `let x = c ? b : a;`.
- **Detect** a `Decl` for `x` followed immediately by an `If` with no
  `else` whose `then` block is exactly one `Assign` to `x`.
- **Skip** `a` is not pure — it is evaluated before `c` in the original and
  after it in the ternary; `c` reads `x` (the ternary binds `x` later);
  `x` is `const` or has a written type that the ternary cannot infer.

### 2.3 An `if`/`else` that only chooses values
- **Instead** `if (c) { x = a; } else { x = b; };`
- **Write** `x = c ? a : b;`.
- **Detect** an `If` with both arms a single `Assign` to the same name.
- **Skip** the name is a `const`; the arms assign different names.

### 2.4 An `if`/`else` that only returns
- **Instead** `if (c) { return a; } else { return b; };`
- **Write** `return c ? a : b;`; when `a`/`b` are `true`/`false` (either
  order) it is `return c;` or `return !c;`.
- **Detect** as 2.3 with `K.ret` wraps; also the tail form
  `if (c) { return a; }; return b;`, where the `if` is the second-to-last
  statement of a list and the last is the other `return`.
- **Skip** the function is `void` (its returns carry no value); one arm
  falls through instead of returning.

### 2.5 A flag that only exists to stop the loop
- **Instead** `let f = true; while (f) { ... f = false; ... };`,
  `while (f == false) { ... f = true; ... }`
- **Write** `while (true) { ... break; ... };` — replace the assignment
  that ends the loop with `break`, and keep `f = false;` in front of the
  `break` when `f` is read after the loop.
- **Detect** a `While` whose condition is the local `f` (or `f == true` /
  `f == false`); `f` is declared with a bool literal immediately before the
  loop; every assignment to `f` is inside the loop; the loop has no other
  exit.
- **Skip** an assignment to `f` can also *continue* the loop (then `f` is
  real state, not a flag); `f` is captured by a closure that reads it
  between iterations. When `f` is read after the loop, each exit site keeps
  its `f = <value>;` in front of the `break`; that is not a skip.

### 2.6 `while (true)` with a leading guard
- **Instead** `while (true) { if (!c) { break; } BODY }`
- **Write** `while (c) { BODY }`.
- **Detect** the first statement of a `while (true)` body is an `If` with
  no `else` whose `then` is exactly `break`; `c` may be written `!c`, in
  which case the rewrite drops the `!`.
- **Skip** the guard is not the first statement (the body would run once
  more); the guard has an `else`.

### 2.7 Boolean comparison in a condition
- **Instead** `if (x == true)`, `while (x == false)`, ...
- **Write** `if (x)`, `while (!x)`, ...
- **Detect** 1.9 used as a condition (`If.cond`, `While.cond`, a `&&`/`||`
  operand in one).
- **Skip** the comparison's value is used as a value, not as a condition.

### 2.8 Index loop to range `for`
- **Instead** `let i = lo; while (i < hi) { BODY; i = i + 1; };`
- **Write** `for i in lo..hi { BODY }`; `i <= hi` is `lo..hi + 1`.
- **Detect** a `Decl` for `i` immediately before the loop; the condition is
  `i < hi`; the last statement of the body is exactly `i = i + 1` (or
  `i++`, `i += 1`); `i` is assigned nowhere else.
- **Skip** a `continue` in the body (it skips the increment in the `while`
  but advances in the `for`); `i` is read after the loop (the range
  variable does not escape it); the step is not 1; the loop mutates `hi`.

### 2.9 A predicate scan
- **Instead**
  `let i = lo; let blank = true; while (blank && i < hi) { let c = byte_at(src, i); blank = isspace(c); i = i + 1; }; blank`
- **Write** that is a `for`:
  `let blank = true; for i in lo..hi { if (!isspace(src[i])) { blank = false; break; } };`
  — or, when nothing but the answer is wanted,
  `let i = lo; while (i < hi && isspace(src[i])) { i = i + 1; }; i == hi`.
- **Detect** a `While` whose condition is `flag && i < hi` (either order);
  `flag` is a bool local declared before the loop; the body's only writes
  are `flag = <predicate of the element at i>` and `i = i + 1`; nothing
  else reads or writes `flag`.
- **Skip** the body does more than the scan (side effects per character);
  the predicate reads anything but the current element; `i` is read after
  the loop and the answer form cannot express it.

### 2.10 A variable read once
- **Instead** `let x = E; ... use(x) ...` where `x` is read exactly once
- **Write** `E` in place of that read, dropping the binding.
- **Detect** a local whose read count is 1, whose single read is the
  statement after its `Decl`, and whose value is never assigned again.
- **Skip** `E` is not pure, or anything between the `Decl` and the read can
  change what `E` reads (a call, an assignment through a pointer); `x` is
  captured by a closure; the declaration is `const` and its name documents
  the value; the read is inside a loop and `E` is not loop-invariant.
- The tail case is worth its own line: `let x = E; return x;` → `return E;`.

### 2.11 `none` test into `if let`
- **Instead** `let x = E; if (x == none) { A } else { B }` where `B` reads
  `x!`
- **Write** `if let some(x) = E { B } else { A }` (arms swapped).
- **Detect** a `Decl` for `x` followed by an `If` whose condition is
  `x == none` or `x != none`; the arm that reads `x!` becomes the `then`
  of the rewrite.
- **Skip** either arm reads `x` without `!`; the `Decl` has a written type;
  `x` is read after the `if`.

## 3. Loops that are array methods

### 3.1 Index `while` to `foreach`
- **Instead** `let i = 0; while (i < len(a)) { B; i = i + 1; };`
- **Write** `a.foreach((e, i) => { B });`.
- **Detect** the `Decl`/`While`/increment shape of 2.8 with `hi = len(a)`.
- **Skip** `a` is resized in `B`; the index is read after the loop; `B` has
  a `return`/`break`/`continue` (they would leave the closure, not the
  function); `B` is empty (delete the loop instead).

### 3.2 Builder loop to `map`
- **Instead** `let out: [T] = []; foreach (x in a) { out += f(x); }; out`
- **Write** `a.map((x) => f(x))`.
- **Detect** a fresh `out` (a `Decl` with an empty array literal) whose
  every write inside the loop is one `+=` of a value derived from the
  iteration variable, and whose only read is the following `return`/tail.
- **Skip** `out` existed before the loop or is read inside it; the loop
  appends conditionally or more than once per iteration; the loop has an
  early exit; the element type differs from `T`.

### 3.3 Builder loop to `filter`
- **Instead** the same builder with `if (p(x)) { out += x; };`
- **Write** `a.filter((x) => p(x))`.
- **Detect** 3.2 where the only statement is an `If` with no `else` whose
  `then` appends the iteration variable itself.
- **Skip** as 3.2.

### 3.4 Search loops
- **Instead** a loop that returns `false` on `!p(x)` and `true` after →
  **Write** `a.all((e) => p(e))`;
  `true` on `p(x)` and `false` after → `a.some((e) => p(e))`;
  the first element where `p` → `a.find((e) => p(e))`;
  the first `i` where `a[i] == v`, else `-1` → `a.index(v)`;
  `acc = f(acc, x)` over the whole array → `a.reduce((acc, x) => f(acc, x), init)`.
- **Detect** a loop whose body is exactly one `If` with no `else` holding
  the `return`, and whose fall-through after the loop is the sentinel.
- **Skip** the predicate is not pure; the loop also does anything else;
  `find` is only for a function already returning `T?` (otherwise the
  rewrite changes the signature).

### 3.5 `range(len(a))` to element iteration
- **Instead** `foreach (i in range(len(a))) { B(a[i]) }`
- **Write** `foreach (e in a) { B(e) }`, or `a.foreach((e, i) => { B })`
  when the index is used too.
- **Detect** a `Foreach` whose iterable is `range(len(a))` and whose body
  reads `a[i]` and nothing else that needs `i`.
- **Skip** `a` is resized in the body; the body assigns `a[i]` (an element
  write is fine with `a.foreach((e, i) => ...)`, but not with `foreach (e
  in a)`).

## 4. Closures

### 4.1 Anonymous `def` literal to arrow
- **Instead** `def (x) { ... }` passed as an argument
- **Write** `(x) => ...`.
- **Detect** a `Func` literal (no `label`, no name) in an argument position.
- **Skip** the body is a block with statements and the arrow form is not
  shorter; the literal is bound to a name (`let f = def ...`) — then it is
  a closure, and the arrow form is the same length.

## 5. Needs a language feature

### 5.1 `in`
- `c in s` — a `byte` or one-char `str` occurs in `s`; a longer `str` is a
  substring test.
- `e in a` — some element of `a` equals `e` (the element type is `e`'s).
- Returns `bool`. Desugars to `index_of(s, c) >= 0` / `a.index(e) >= 0`,
  so it short-circuits nothing and costs one pass.
- It is the rewrite target of 1.6 and 1.8; without it those rules can only
  suggest `index_of(...) >= 0`.

## 6. Correctness (already warned)

- `x = x` — assigned to itself.
- `x < x` (and `x > x`) — always false.
- `a / 0`, `a % 0` — division by zero.
- code after a `return` — unreachable.
- a computed value nobody reads.
- `f()` whose result is dropped.
- a record or map literal with a duplicate key.
- an unused local, or one assigned but never read.
- a top-level name, or a `type` alias, declared more than once.
- one type written out in full twice, or where an alias already names it.
- a top-level statement beside a meta block — it runs twice.
- a value-used `+=` on a string inside a loop — copies the whole string.

## 7. TODO

- **`mktok` token types are strings.** `mktok("op", ...)`,
  `mktok("punct", ...)`, `mktok("id", ...)`, ... carry the token type as a
  bare string, so a typo is a silently different token type rather than an
  error. Give each type a `const` (e.g. `const TOK_OP = "op";`) and pass
  the name, so a mistyped one is an undefined-variable error. The same for
  every `t == "id"` / `tt(toks, p) == "punct"` comparison in the parser and
  the lexer.
- **`in`** (section 5) is itself unimplemented; rules 1.6 and 1.8 wait on
  it.
