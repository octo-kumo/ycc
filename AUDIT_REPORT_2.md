# Adversarial Security & Correctness Audit Report

**Project:** Custom Language Compiler/VM (`/home/yun/Projects/compiler`)
**Date:** 2026-07-28
**Auditor:** Hermes Agent (automated adversarial audit)
**Tests run:** 65 adversarial `.y` programs, both VM and compiled modes, plus valgrind

---

## Summary Table

| # | Severity | Category | Title | File(s) |
|---|----------|----------|-------|---------|
| 1 | CRITICAL | Memory Safety | NULL deref on empty block result | vm.c:555, main.c:33 |
| 2 | CRITICAL | Parser | Exponential backtracking on nested parens (DoS) | parser.c:1323-1328 |
| 3 | CRITICAL | Memory Safety | Stack overflow via deep recursion (no limit) | vm.c:309 (vm_execute) |
| 4 | HIGH | Logic / VM-Codegen Divergence | Negative array index returns wrong element in VM | vm.c:646 |
| 5 | HIGH | Logic / VM-Codegen Divergence | Negative array index assignment crashes in VM, works differently in compiled | vm.c:829 |
| 6 | HIGH | Parser | Chained array indexing `x[1][0]` fails to parse | parser.c:846-913 |
| 7 | HIGH | Security | `exec()` builtin passes user strings to `system()` — shell injection | lib.c:220-226, runtime.c:659-663 |
| 8 | MEDIUM | Logic | Integer literal overflow silently wraps | parser.c:93-100 |
| 9 | MEDIUM | Logic | Arithmetic overflow silently wraps (LONG_MAX + 1) | vm.c:386, runtime.c:304 |
| 10 | MEDIUM | Logic | Null byte in string truncates output (len reports wrong value) | parser.c:586, vm.c:82 |
| 11 | MEDIUM | VM-Codegen Divergence | `push()` intermittent segfault in VM | vm.c (push builtin) |
| 12 | MEDIUM | Logic | Duplicate map keys silently accepted, first wins | parser.c:1241-1273, vm.c:617-628 |
| 13 | LOW | VM-Codegen Divergence | `typeof()` returns different types in VM vs compiled | vm.c:151-196, runtime.c:525-573 |
| 14 | LOW | Memory Safety | `val_to_str` uses static 1024-byte buffer (truncation, not thread-safe) | vm.c:146-150 |
| 15 | LOW | Parser | Unterminated string prints error twice in VM mode | parser.c:610, main.c:173-177 |

---

## Detailed Findings

### 1. CRITICAL — NULL Pointer Dereference on Empty Block Result

**Category:** Memory Safety
**File:** `vm.c:555` (EXPR_EBLOCK handler), `main.c:33` (val_print call)

**Description:** When a block expression has zero statements (e.g., `if (true) {}`), `vm_execute` for `EXPR_EBLOCK` initializes `last = NULL` and the loop body never executes, so it returns `NULL`. In `main.c:33`, `val_print(output)` is called on this NULL pointer, which calls `val_to_str(NULL)` → `val_to_buf(NULL, ...)` → dereferences `val->type` at `vm.c:76`, causing a segfault.

**Reproduction:**
```
echo 'if (true) {}' > /tmp/test.y
./compiler /tmp/test.y
# → Segmentation fault (exit 139)
```

**Valgrind confirms:**
```
Access not within mapped region at address 0x0
   at 0x11CDB0: val_to_buf (vm.c:76)
```

**Fix:** Add `if (!val) return;` guard in `val_to_buf` and `val_print`, or return `nval(VAL_NULL)` instead of NULL from empty blocks.

---

### 2. CRITICAL — Exponential Backtracking on Nested Parentheses (Parser DoS)

**Category:** Parser
**File:** `parser.c:1323-1328` (EXPR_INLINE_PARSERS list)

**Description:** The parser uses ordered-choice (PEG-style) with multiple parsers that can each independently parse parenthesized expressions. For input with N nested parentheses like `((((1))))`:

1. `ast_parse_binary_op` calls `ast__parse_inside_binary_op` → tries `ast_parse_paren_expr` (recursively parses inner N-1 parens)
2. If no binary operator follows, it returns `anone` and **frees the parsed result**
3. `ast_parse_function_call` then tries `ast_parse_var_or_paren_expr` → `ast_parse_paren_expr` again (re-parses the same N-1 inner parens from scratch)
4. `ast_parse_paren_expr` in the inline list tries a **third** time

Each level of nesting causes the inner expression to be parsed ~3 times. Total work is O(3^N). With 50 nested parens, this is ~7×10²³ operations — effectively an infinite loop.

**Reproduction:**
```
echo 'print((((((((((((((((((((((((((((((((((((((((((((((((((1))))))))))))))))))))))))))))))))))))))))))))))))))' > /tmp/test.y
timeout 10 ./compiler /tmp/test.y
# → Times out (exit 124)
```

**Fix:** Add memoization (packrat parsing), or restructure the parser so parenthesized expressions are only attempted once per position. Alternatively, add a recursion/attempt depth limit.

---

### 3. CRITICAL — Stack Overflow via Deep Recursion (No Depth Limit)

**Category:** Memory Safety
**File:** `vm.c:309` (`vm_execute` recursive dispatch)

**Description:** `vm_execute` is a recursive tree-walker with no depth limit. A user-defined recursive function with ~100,000 iterations (e.g., factorial of 100000) causes unbounded C stack growth until SIGSEGV. The compiled mode also crashes but at a higher threshold since C function calls are more stack-efficient.

**Reproduction:**
```
cat > /tmp/test.y << 'EOF'
def f(x: long) -> long {
    if (x == 0) { 1 } else { x * self(x - 1) }
};
print(f(100000))
EOF
./compiler /tmp/test.y
# → Segmentation fault (exit 139)
```

**Valgrind confirms:** Stack overflow in main thread (8MB stack exhausted).

**Fix:** Add a recursion depth counter to `vm_execute` and abort with an error message when a configurable limit (e.g., 10,000) is exceeded.

---

### 4. HIGH — Negative Array Index Returns Wrong Element in VM (Signed/Unsigned Bug)

**Category:** Logic Bug / VM-Codegen Divergence
**File:** `vm.c:646`

**Description:** The VM's negative index normalization uses:
```c
idx = (idx % array_val->data.arr->count + array_val->data.arr->count) %
      array_val->data.arr->count;
```
Here `idx` is `long` (signed) but `array_val->data.arr->count` is `size_t` (unsigned). C's usual arithmetic conversions promote `idx` to `size_t` before the modulo. So `-1` becomes `SIZE_MAX` (18446744073709551615), and `SIZE_MAX % 3 == 0`, yielding element[0] instead of element[2].

The compiled runtime (`runtime.c:411`) correctly casts to `long` first:
```c
long count = (long)arr->data.arr->count;
i = ((i % count) + count) % count;
```

**Reproduction:**
```
cat > /tmp/test.y << 'EOF'
let x = [10, 20, 30, 40, 50];
print(x[-1]);
print(x[-2]);
print(x[-5])
EOF
./compiler /tmp/test.y          # VM: prints 10, 50, 20 (WRONG)
./compiler --compile /tmp/test.y -o /tmp/bin && /tmp/bin  # Compiled: prints 50, 40, 10 (CORRECT)
```

**Expected:** `x[-1]` → 50 (last element), `x[-2]` → 40, `x[-5]` → 10
**VM actual:** `x[-1]` → 10 (first element!), `x[-2]` → 50, `x[-5]` → 20

**Fix:** Cast `count` to `long` before the modulo in `vm.c:646`:
```c
long count = (long)array_val->data.arr->count;
idx = (idx % count + count) % count;
```

---

### 5. HIGH — Negative Array Index Assignment Crashes in VM

**Category:** Logic Bug / VM-Codegen Divergence
**File:** `vm.c:829`

**Description:** Array index assignment (`x[-1] = 99`) uses a bounds check that rejects negative indices:
```c
if (idx < 0 || (size_t)idx >= array_val->data.arr->count) {
    fprintf(stderr, "Array index out of bounds\n");
    exit(1);
}
```
Unlike array *reading* (which attempts negative index normalization), array *writing* does not normalize negative indices. This is inconsistent: `x[-1]` reads the "first" element (due to bug #4), but `x[-1] = val` crashes.

The compiled runtime (`runtime.c:743`) also rejects negative indices in `y_arr_set`, so both modes crash — but the VM's inconsistency between read and write is a logic bug.

**Reproduction:**
```
cat > /tmp/test.y << 'EOF'
let x = [1, 2, 3];
x[-1] = 99;
print(x)
EOF
./compiler /tmp/test.y   # VM: "Array index out of bounds", exit 1
```

---

### 6. HIGH — Chained Array Indexing `x[1][0]` Fails to Parse

**Category:** Parser
**File:** `parser.c:846-913` (`ast_parse_array_idx`)

**Description:** The parser cannot handle chained array indexing like `x[1][0]`. After parsing `x[1]`, the remaining `[0]` is not consumed. The expression `print(x[1][0])` is parsed as `print` (bare identifier) followed by unparsed input `(x[1][0])`.

This is because `ast_parse_array_idx` calls `ast_parse_var_or_paren_expr` for the array part, which only handles simple variables and parenthesized expressions — not another array index expression. The result is that nested/chained indexing silently produces wrong ASTs.

**Reproduction:**
```
cat > /tmp/test.y << 'EOF'
let x = [1, [2, [3]]];
print(x[1][0])
EOF
./compiler /tmp/test.y
# → Warning: Unparsed input remaining: '(x[1][0])'
# → Result: <function (<inferred>)->()>   (prints the `print` function itself!)
```

**Fix:** Make `ast_parse_array_idx` recursive — after parsing one `[idx]`, check for another `[` and chain.

---

### 7. HIGH — Shell Injection via `exec()` Builtin

**Category:** Security
**File:** `lib.c:220-226` (VM), `runtime.c:659-663` (compiled)

**Description:** The `exec()` builtin passes its string argument directly to `system()`, which invokes `/bin/sh -c <cmd>`. Any user-controlled string can inject arbitrary shell commands via `;`, `|`, `&&`, backticks, `$()`, etc.

**Reproduction:**
```
cat > /tmp/test.y << 'EOF'
exec("echo pwned > /tmp/audit_pwned; echo injected")
EOF
./compiler /tmp/test.y
cat /tmp/audit_pwned   # → "pwned"
```

Both VM and compiled modes are affected. This is by design (it's a shell builtin), but it means any `.y` program that processes untrusted input and passes it to `exec()` is vulnerable to command injection.

**Mitigation:** Document the risk prominently. Consider adding a sandboxed mode or an `exec_argv()` variant that uses `execvp()` with an argument array instead of `system()`.

---

### 8. MEDIUM — Integer Literal Overflow Silently Wraps

**Category:** Logic Bug
**File:** `parser.c:93-100` (`digit_list_to_long`)

**Description:** Parsing integer literals uses `number = number * 10 + digit` in a `long` with no overflow check. Literals exceeding `LONG_MAX` silently wrap around.

**Reproduction:**
```
echo 'let x = 99999999999999999999999999999999999999; print(x)' > /tmp/test.y
./compiler /tmp/test.y
# → [print] 687399551400673279  (silently wrong)
```

**Fix:** Check for overflow during digit accumulation and emit a parse error or warning.

---

### 9. MEDIUM — Arithmetic Overflow Silently Wraps

**Category:** Logic Bug
**File:** `vm.c:386` (`__ISCALCULATION` macro), `runtime.c:304` (`NUMERIC_BINOP`)

**Description:** Integer arithmetic (`+`, `-`, `*`) uses C's native `long` operations with no overflow detection. `LONG_MAX + 1` silently wraps to `LONG_MIN`.

**Reproduction:**
```
echo 'let x = 9223372036854775807; print(x + 1)' > /tmp/test.y
./compiler /tmp/test.y
# → [print] -9223372036854775808
```

Both VM and compiled modes exhibit identical (wrong) behavior. This is consistent but silent.

---

### 10. MEDIUM — Null Byte in String Truncates Output

**Category:** Logic Bug
**File:** `parser.c:586` (escape handling), `vm.c:82` (`val_to_buf` VAL_STR case)

**Description:** The parser correctly handles `\x00` escapes and stores the null byte in the string data with the correct length. However, all string output functions (`printf("%s", ...)`, `strlen()`, `strcmp()`) treat the null byte as a string terminator. A string `"hello\x00world"` has `length=11` in the AST but `len()` returns 5 and `print()` only shows `hello`.

**Reproduction:**
```
echo 'let x = "hello\x00world"; print(len(x))' > /tmp/test.y
./compiler /tmp/test.y
# → [print] 5   (should be 11)
```

The `EStr.length` field is correctly set to 11 by the parser, but `len()` in `lib.c:197` uses `strlen(x->data.s)` instead of the stored length.

---

### 11. MEDIUM — `push()` Intermittent Segfault in VM

**Category:** Memory Safety
**File:** `lib.c:294-310` (push builtin)

**Description:** The `push()` builtin intermittently segfaults in VM mode. The crash is non-deterministic (observed in ~30% of runs for the same input), suggesting a use-after-free or uninitialized memory issue. Under valgrind the test passes cleanly (Heisenbug — valgrind's memory layout changes mask the issue).

**Reproduction:**
```
cat > /tmp/test.y << 'EOF'
let x = [1, 2, 3];
let y = push(x, 4);
print(y);
print(x)
EOF
# Run multiple times:
for i in $(seq 10); do ./compiler /tmp/test.y 2>&1 | grep -c Segmentation; done
# → Intermittent segfaults
```

**Likely cause:** The `DEFINE_EXTERNAL_FUNC2` macro retrieves parameters via `vm_scope_get`, which returns a pointer into the scope's map. If the scope is modified or freed between parameter retrieval and use, the pointer dangles. The `push` builtin clones elements from `arr`, but if `arr` itself is a dangling pointer, the clone reads freed memory.

---

### 12. MEDIUM — Duplicate Map Keys Silently Accepted

**Category:** Logic Bug
**File:** `parser.c:1241-1273` (map parsing), `vm.c:617-628` (map construction)

**Description:** Map literals with duplicate keys (`{a: 1, a: 2}`) are accepted without warning. The VM stores both entries, and lookup returns the **first** match. This is surprising behavior — most languages either reject duplicates or use last-wins semantics.

**Reproduction:**
```
echo 'let x = {a: 1, a: 2}; print(x.a)' > /tmp/test.y
./compiler /tmp/test.y
# → [print] 1   (first value wins, no warning)
```

---

### 13. LOW — `typeof()` Returns Different Types in VM vs Compiled

**Category:** VM-Codegen Divergence
**File:** `vm.c:151-196` (`val_type`), `runtime.c:525-573` (`y_type_name`)

**Description:** The VM's `typeof()` returns a `VAL_TYPE` value (a type object), while the compiled runtime returns a string. For simple types like `long`, both print `long`, but for complex types (arrays, maps, functions) the output format differs.

---

### 14. LOW — `val_to_str` Uses Static Buffer

**Category:** Memory Safety
**File:** `vm.c:146-150`

**Description:** `val_to_str` returns a pointer to a `static char buf[1024]`. This means:
- Nested calls overwrite each other (e.g., printing an array of strings)
- Not thread-safe
- Strings longer than 1024 chars are silently truncated

The compiled runtime (`runtime.c:255-260`) correctly uses `malloc(4096)` and returns an owned buffer.

---

### 15. LOW — Unterminated String Error Printed Twice in VM Mode

**Category:** Parser
**File:** `parser.c:610`, `main.c:173-177`

**Description:** In VM mode, the parser is invoked twice (once for `ast_walk`/`ast_print_code` and once for actual execution), so the "Unterminated string literal" error message is printed twice. In compiled mode it's printed once.

---

## Test Coverage Summary

| Test Range | Count | Categories Covered |
|------------|-------|--------------------|
| t01-t10 | 10 | Empty blocks, neg floats, int overflow, unterminated strings, empty arrays, div-by-zero, exec injection, deep recursion |
| t11-t20 | 10 | Deep parens (DoS), operator precedence, boolean precedence, negative indexing, slicing, string concat |
| t21-t30 | 10 | Map dot access, missing keys, null equality, range, split, join, substr, push, for-range, foreach |
| t31-t40 | 10 | While loops, null bytes, redeclaration, nested arrays, int division, LONG_MIN, LONG overflow, tonum, tostring/typeof, trim |
| t41-t50 | 10 | Multi negative index, slices, array assign, OOB assign, fibonacci, eq+and precedence, cmp+eq, string indexing, cons, cons-nonarr |
| t51-t60 | 10 | Empty map, dup map keys, split empty, join empty, substr OOB, substr neg, C-style for, left-assoc sub, div assoc, mixed precedence |
| t61-t65 | 5 | Null byte v2, chained indexing, if/else, else-if, mixed numeric types |
| **Total** | **65** | |

---

## Recommendations (Priority Order)

1. **Fix NULL deref in empty blocks** (#1) — trivial fix, prevents crash on valid input
2. **Fix negative index signed/unsigned bug** (#4) — one-line cast fix, corrects wrong results
3. **Add parser memoization or depth limit** (#2) — prevents DoS on adversarial input
4. **Add recursion depth limit to VM** (#3) — prevents stack overflow crash
5. **Fix chained array indexing parser** (#6) — enables a common language feature
6. **Add overflow checks for integer literals and arithmetic** (#8, #9) — prevents silent wrong results
7. **Use stored string length instead of strlen** (#10) — fixes null-byte handling
8. **Investigate push() use-after-free** (#11) — intermittent crash suggests memory corruption
