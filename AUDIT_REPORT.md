# Adversarial Security & Correctness Audit Report
## Compiler Project (/tmp/compiler-hermes)

---

## FINDING 1: Missing `break` in O_CONS case — VM crash on `::` operator
**Severity: CRITICAL**
**File: vm.c, lines 487–525 (EXPR_EOP / O_CONS case)**

The `O_CONS` case in `vm_execute` has no `break` statement. After building the
cons array, execution falls through into `O_DOT`, which tries to interpret the
left operand as a map and calls `exit(1)` with "Dot operator is only supported
for map access with string keys".

**Trigger:**
```
let arr = [1, 2, 3];
let result = 0 :: arr;
print(result);
```
**VM output:** `Dot operator is only supported for map access with string keys` → exit(1)
**Compiled output:** `[print] [0, 1, 2, 3]` (correct!)

**VM/codegen divergence:** The `::` operator is completely broken in the VM but
works correctly in compiled mode.

**Fix:** Add `break;` after line 501 (`val->data.arr = new_arr;`).

---

## FINDING 2: Negative float parsing produces wrong value
**Severity: CRITICAL**
**File: parser.c, lines 481–517 (ast_parse_number)**

`parse_long` consumes the sign and integer part, returning e.g. `-3` for input
`-3.14`. Then `ast_parse_number` sees the `.` and parses the fractional part
`14` as a positive fraction `0.14`. It adds this to the integer part:
`-3 + 0.14 = -2.86`. The correct answer is `-3.14`.

The sign is applied to the integer part only; the fraction is always added
positively.

**Trigger:**
```
let x = -3.14;
print(x);
```
**VM output:** `[print] -2.860000` (WRONG, should be -3.14)
**Compiled output:** `[print] -2.860000` (also wrong — same AST)

**Fix:** In `ast_parse_number`, apply the sign to the final combined value:
```c
double result = (double)value + fraction;
if (sign_value < 0) result = -result;
expr->as.efloat = result;
```
Or restructure to parse the sign separately and negate the final float.

---

## FINDING 3: No operator precedence — all binary ops are right-associative
**Severity: CRITICAL**
**File: parser.c, lines 707–742 (ast_parse_binary_op)**

The parser uses a single `ast_parse_binary_op` for ALL operators with no
precedence climbing or Pratt parsing. The left operand is parsed via
`ast__parse_inside_binary_op` (atoms only), and the right operand via
`ast__parse_inline_expr` (which recursively calls `ast_parse_binary_op`).
This makes ALL operators right-associative with equal precedence.

**Trigger 1 — wrong associativity:**
```
let x = 10 - 2 - 3;
print(x);
```
Expected: `(10-2)-3 = 5`. Actual: `10-(2-3) = 11`. **Both VM and compiled print 11.**

**Trigger 2 — wrong precedence:**
```
let x = 2 * 3 + 4;
print(x);
```
Expected: `(2*3)+4 = 10`. Actual: `2*(3+4) = 14`. **Both VM and compiled print 14.**

**Trigger 3 — division associativity causes crash:**
```
let x = 10 / 2 / 5;
print(x);
```
Expected: `(10/2)/5 = 1`. Actual: `10/(2/5) = 10/0` → integer division by zero.
VM silently produces 0 (see Finding 5); compiled mode correctly errors.

**Fix:** Implement precedence climbing or Pratt parsing with standard C-like
precedence levels: `* / %` > `+ -` > `< > <= >=` > `== !=` > `&&` > `||`.

---

## FINDING 4: `else if` crashes the compiler (NULL deref in typechecker)
**Severity: CRITICAL**
**File: parser.c lines 699–704, typecheck.c line 86**

When the parser encounters `else if (...)`, it consumes `else` via
`MAYBE_KEYWORD`, then calls `ast_parse_brace_block` which fails on `if`
(expects `{`). The result has `value = NULL`. The parser sets
`else_branch = NULL` and returns successfully with remaining input starting
at `if`.

The typechecker's `tc_if` then calls `tc_expr(expr->as.if_node.else_branch, scope)`
with a NULL pointer → **segfault**.

**Trigger:**
```
let x = 2;
if (x == 1) {
    print("one");
} else if (x == 2) {
    print("two");
}
```
**Result:** Segmentation fault (exit 139) in both VM and compiled modes.

**Fix:** In `tc_if`, check for NULL else_branch:
```c
if (expr->as.if_node.else_branch) {
    typecheck_result_t else_res = tc_expr(expr->as.if_node.else_branch, scope);
    ...
}
```
Also, the parser should support `else if` by recursively calling
`ast_parse_if` when `ast_parse_brace_block` fails after `else`.

---

## FINDING 5: Integer division by zero — VM silently returns 0
**Severity: HIGH**
**File: vm.c, lines 471–474 (O_DIV case)**

The VM's `O_DIV` uses `__ISCALCULATION(/)` which does `left->data.l / right->data.l`
for two longs. In C, integer division by zero is undefined behavior. On x86-64
Linux, this typically raises SIGFPE, but the VM appears to produce 0 (possibly
due to compiler optimizations or signal handling).

The compiled runtime (`y_div`) correctly checks for zero and calls `exit(1)`.

**Trigger:**
```
let x = 10 / 0;
print(x);
```
**VM output:** `[print] 0` (silently wrong — UB)
**Compiled output:** `runtime error: division by zero` (correct error)

**Fix:** Add a zero check in the VM's O_DIV case before performing integer division.

---

## FINDING 6: Empty array index — VM segfaults (modulo by zero)
**Severity: HIGH**
**File: vm.c, lines 631–633 (EXPR_EARRAY_IDX)**

The VM computes `idx = (idx % count + count) % count` where `count` is
`array_val->data.arr->count`. For an empty array, `count = 0`, causing
modulo-by-zero → **SIGFPE/segfault**.

The compiled runtime (`y_arr_index`) correctly checks for empty arrays.

**Trigger:**
```
let arr = [];
let x = arr[0];
print(x);
```
**VM:** Segmentation fault (exit 139)
**Compiled:** `runtime error: index out of bounds (empty array)` (correct)

**Fix:** Add `if (array_val->data.arr->count == 0) { error; }` before the modulo.

---

## FINDING 7: Empty array slice — both VM and compiled segfault
**Severity: HIGH**
**File: vm.c lines 658–671, runtime.c lines 415–420**

Both VM and runtime have a guard `if (count <= 1 && start >= 1)` that returns
an empty array. But for `a[0:1]` on an empty array, `start = 0`, so the guard
doesn't trigger. Then `start = (start % count + count) % count` with
`count = 0` → modulo by zero → crash.

**Trigger:**
```
let a = [];
let b = a[0:1];
print(b);
```
**VM:** Segmentation fault (exit 139)
**Compiled:** Segmentation fault (exit 139)

**Fix:** Change guard to `if (count == 0) return empty_array;` before any modulo.

---

## FINDING 8: `if` without `else` crashes typechecker (NULL deref)
**Severity: HIGH**
**File: typecheck.c, line 86**

`tc_if` unconditionally calls `tc_expr(expr->as.if_node.else_branch, scope)`.
When there's no else branch, `else_branch` is NULL → segfault.

**Trigger:**
```
let x = 1;
if (x == 1) {
    print("yes");
}
```
**Result:** Segmentation fault (exit 139)

**Fix:** Guard with `if (expr->as.if_node.else_branch)` before typechecking it.
Return `TYPE_NULL` when there's no else branch.

---

## FINDING 9: `val_type` crashes on empty arrays (OOB read)
**Severity: HIGH**
**File: vm.c, lines 170–176 (val_type, VAL_ARR case)**

`val_type` reads `val->data.arr->elements[0]` to determine the element type,
with the comment "assume all elements have the same type". For an empty array,
this is an out-of-bounds read → segfault or garbage.

**Trigger:**
```
let arr = [];
print(typeof(arr));
```
**Result:** Segmentation fault (exit 139)

**Fix:** Check `count == 0` and return a generic/inferred array type.

---

## FINDING 10: `y_and`/`y_or` type confusion in runtime (VM/codegen divergence)
**Severity: HIGH**
**File: runtime.c, lines 377–382**

The runtime's `y_and` and `y_or` read `a->data.b` without checking `a->type`.
If `a` is a Y_LONG, this reads the low byte of the long as a bool (union
type confusion). The VM correctly checks types and exits with an error.

**Trigger:**
```
let x = 1 && 2;
print(x);
```
**VM:** Type check fails: "Operands of boolean operator must be boolean"
**Compiled:** `[print] true` (silently wrong — reads union bytes as bool)

**Security implication:** A malicious program can probe memory layout by
passing non-bool values to `&&`/`||` in compiled mode.

**Fix:** Add type checks in `y_and`/`y_or`:
```c
if (a->type != Y_BOOL || b->type != Y_BOOL) {
    fprintf(stderr, "runtime error: && requires booleans\n"); exit(1);
}
```

---

## FINDING 11: Unterminated string literal calls exit(1) — compiler DoS
**Severity: MEDIUM**
**File: parser.c, lines 600–603 (ast_parse_string)**

An unterminated string literal causes `exit(1)` instead of returning a parse
error. This means any malformed input with an unclosed quote kills the compiler
process immediately, bypassing all cleanup.

**Trigger:** A .y file containing `"hello` with no closing quote.

**Fix:** Return `anone(original_input)` instead of calling `exit(1)`.

---

## FINDING 12: Integer overflow in number parsing (UB)
**Severity: MEDIUM**
**File: parser.c, lines 93–100 (digit_list_to_long)**

`digit_list_to_long` computes `number = number * 10 + digit` without overflow
checking. A literal like `99999999999999999999` overflows `long` — undefined
behavior in C. Could produce any value, including negative numbers.

**Trigger:**
```
let x = 99999999999999999999;
print(x);
```

**Fix:** Use `strtoul` with `ERANGE` checking, or accumulate in `unsigned long`
and check against `LONG_MAX`.

---

## FINDING 13: Generated C function bodies leak their scope (never freed)
**Severity: MEDIUM**
**File: codegen.c, lines 120–137 (emit_func_def)**

Every generated C function does:
```c
YScope *scope = malloc(sizeof(YScope));
y_scope_init(scope, closure);
...
return _result;
```
The scope is never released. Every function call leaks the scope struct and
all its entries (parameter bindings + local variables). For programs with
heavy function usage, this is unbounded memory growth.

**Fix:** Add `y_scope_release(scope);` before `return _result;` — but this
requires ensuring no closures capture the scope. A better approach: use a
stack-allocated scope or add a cleanup mechanism.

---

## FINDING 14: `y_clone` leaks the intermediate pointer array
**Severity: LOW**
**File: runtime.c, lines 160–164 (y_clone, Y_ARR case)**

`y_clone` allocates `elems`, fills it, then passes it to `y_mk_arr` which
copies the pointer array to a new heap allocation. The original `elems` is
never freed. Same pattern in Y_MAP case (line 167–173). Also in `y_cons`
(line 461) and `y_arr_slice` (line 431).

Each call leaks `sizeof(YValue*) * count` bytes.

**Fix:** Free `elems` after `y_mk_arr` returns, or make `y_mk_arr` take
ownership of the array instead of copying it.

---

## FINDING 15: `y_escape_c_string` uses greedy `\xNN` escapes (latent bug)
**Severity: LOW**
**File: runtime.c, lines 566–588**

`y_escape_c_string` uses `\x%02x` for non-printable bytes. In C, `\x` escapes
are greedy — `\x41B` is parsed as a single hex value `0x41B`, not `\x41`
followed by `B`. If a non-printable byte is followed by a hex digit character,
the generated C string literal will have wrong content.

Note: codegen.c's `escape_c_str` correctly uses octal `\%03o` which is
fixed-width. This function appears unused by codegen but is exported in the
header.

**Fix:** Use octal escapes (`\%03o`) like codegen.c does.

---

## FINDING 16: `for` loop scope not released in generated code
**Severity: LOW**
**File: codegen.c, lines 414–446 (emit_for), 448–463 (emit_foreach), 465–483 (emit_forrange)**

All loop emissions create a `YScope *scope = malloc(sizeof(YScope))` but
never release it. The `_last` value is returned but the scope leaks.

**Fix:** Add `y_scope_release(scope);` before returning `_last` (requires
careful ordering to not free values still in use).

---

## Summary Table

| # | Severity | Component | Bug |
|---|----------|-----------|-----|
| 1 | CRITICAL | vm.c | Missing break in O_CONS → falls through to O_DOT, `::` broken in VM |
| 2 | CRITICAL | parser.c | Negative floats wrong: -3.14 → -2.86 |
| 3 | CRITICAL | parser.c | No operator precedence, all ops right-associative |
| 4 | CRITICAL | parser.c + typecheck.c | `else if` → NULL deref segfault |
| 5 | HIGH | vm.c | Integer div by zero → UB (silently returns 0) |
| 6 | HIGH | vm.c | Empty array index → segfault (mod by zero) |
| 7 | HIGH | vm.c + runtime.c | Empty array slice → segfault (mod by zero) |
| 8 | HIGH | typecheck.c | `if` without `else` → NULL deref segfault |
| 9 | HIGH | vm.c | `val_type` on empty array → OOB read |
| 10 | HIGH | runtime.c | `y_and`/`y_or` type confusion (no type check) |
| 11 | MEDIUM | parser.c | Unterminated string → exit(1) DoS |
| 12 | MEDIUM | parser.c | Integer overflow in number parsing (UB) |
| 13 | MEDIUM | codegen.c | Generated functions leak scope (never freed) |
| 14 | LOW | runtime.c | y_clone leaks intermediate pointer arrays |
| 15 | LOW | runtime.c | y_escape_c_string uses greedy \xNN |
| 16 | LOW | codegen.c | Loop scopes never released in generated code |
