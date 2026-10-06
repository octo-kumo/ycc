# List of LANGUAGE features to add to YCC

Language features to be added, insert a reason why it is useful, a snippet of how it looks like

Each entry says what it buys and what it costs today.

***INSTRUCTIONS WHEN FINISH*** remove the TODO item from this file when it has been completed

All feature items that were open in this file are now implemented.

The additions, with their native fixtures:

  * primitive, array and map members in a union, boxed behind hidden
    one-field records (`test/y/native/t357_union_primitives.y`);
  * `json{ ... }` / `json[ ... ]` literals, desugared by the parser to
    `std/json.y` calls (`test/y/native/t358_json_literals.y`);
  * `break name` / `continue name`, resolved to an enclosing loop by depth
    (`test/y/native/t359_break_labels.y`);
  * tuples, represented as records with positional field names (`$0`, ...)
    so `.0` and inferred tuple values use the ordinary record backend
    (`test/y/native/t356_tuple_types.y`);
  * parameter types inferred from a literal in the body or from a literal
    actual at a call site (`test/y/native/t360_param_infer.y`).

## Not moved: already implemented

Checked and working, so these stay only in `TODO.y` as history:

| `TODO.y` item | Status |
|---|---|
| `while cond { }` without brackets | implemented |
| `if cond { }` without brackets | implemented |
| `0b10001` binary literal | implemented (`0x1F` and `_` grouping too) |
| `0o755` octal literal | implemented (`0O17`, `_` grouping, and the one `radix_of` prefix test the other radixes now share) |

# DONE: the tree shake drops functions, not data (was item 9)

Done in round 28. The emitter brackets every top-level global's initializer
with two labels named for the cell (`ygiS_<cell>` / `ygiE_<cell>`), and the
link step deletes that range when nothing reads the cell -- and refuses to
unless the range is pure: no call except `y_alloc`, no store to another cell,
no raw text. The shake that follows drops whatever only that range called.
Both copies carry it, byte-identical.

Measured:

| program | before | after |
| --- | --- | --- |
| `import math; print(7);` | 7678 | **973** |
| `import regex;` / `import crypto;` / `import fs;` unused | 1155 / 1393 / 1045 | 973 |
| 400 unused `[long; 8]` tables | 78173 | **973** |
| three dead tables beside one live one | 1491 | 1491 (they cost nothing) |
| `print(math.sqrt(9.0))` (math used) | 17132 | 10427 |

`test/treeshake/costs.txt`: math 6705 -> 0, regex 182 -> 0, crypto 420 -> 0,
fs 72 -> 0. What is left is the rule doing its job, not a gap: x509 and tls 94,
json 25 -- top-level statements with an effect, which must run whether or not
anything reads their value.

Two lessons worth keeping, both learned the hard way across six rounds:

  * **`ys_slice`, not `ya_slice`.** A `str` in the C copy is not an array, and
    `ya_slice` on one answers EMPTY. `mark_cell` used it, so every mark looked
    like a non-mark, nothing was deleted, and the pass was silently a no-op in
    the C copy -- with the Y copy working perfectly, which is why the port gate
    is not optional. PORTING.md's ys_/ya_ rule applies to every string
    operation, not just the obvious ones.
  * **An unread cell's initializer is not dead.** The first version asked only
    "is the cell read", deleted `let result = main(...)` -- the call to `main`
    -- and produced a compiler that exited 0 and did nothing.
    `test/y/native/t348_unread_init_side_effect.y` is that regression, and
    `range_is_pure` is why it cannot come back.

Also: probes that "proved" the marks were missing were themselves wrong (a
buggy guard in the probe), so the three rounds spent chasing "the marks are
not in the items" were chasing nothing. Dump the first few items and read
them; do not trust a counter you have not validated.

# DONE: array methods and arrow closures

Added `const` compile-time array immutability enforcement, in-place mutation
methods (`pop`, `shift`, `remove(idx[, n])`, `push`, `unshift`, `insert`),
iteration methods (`foreach`, `map`, `all`, `some`, `filter`, `find`,
`reduce`), `flat`, `index`, `sort` and `sorted`, and arrow-closure syntax
(`e => e + 1`, `(acc, v) => acc + v`, `() => 0`). The checker adapts closure
arity to the method (a missing index parameter is allowed). Covered by
`test/y/native/t361_array_methods.y`, `e196_array_method_errors.y`,
`e197_const_array_method.y` and the port gate.
