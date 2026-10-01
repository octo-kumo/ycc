# Test coverage

What the tests cover, as a list `test/sh/test_coverage.sh` checks (it runs
in `make test`). The suite reads the compiler sources, the reference manual
(`docs/src`) and the tests; it fails when

- a diagnostic the compiler can print has no test expecting its message
  (and no row below saying why none can),
- a builtin or string method of `09-builtins.tex` is never called by a test
  whose output is checked,
- a keyword is used by no `t*.y` program,
- a section of the manual has no row in the feature table, or a row names a
  test that does not exist or does not check its output.

"Checked" means the test asserts what happens: a native fixture
(`native/t*.y` against its `.expected`, `native/e*.y` against its
`// expect-error:` markers), an inline case of `test_comprehensive.sh` or
`test_loops.sh`, or a `test/sh` suite. The `audit/` and `examples/`
programs only check that the two compilers agree, so they are not evidence
that a feature works.

## Features

One row per feature of each section of the manual: the manual file, the
section title (exactly as in the `.tex`), the feature, and the tests that
exercise it. Tests are `native/NAME.y`, `sh/test_NAME.sh`, or an inline
case as `comprehensive: NAME` / `loops: NAME` (a case whose name starts
with NAME). A section that specifies nothing a program can do (the
manual's notation, say) has one row whose Tests cell is `none: ` and the
reason.

| Manual | Section | Feature | Tests |
|---|---|---|---|
| 01-overview | Overview | Imperative programs compiled to native static executables | `sh/test_native.sh`, `native/t01_arith.y`, `native/t08_syscall.y` |
| 01-overview | Implementations | Reference/C-copy byte identity and self-compilation fixpoint | `sh/test_port.sh`, `sh/test_fixpoint.sh` |
| 01-overview | Notation | EBNF conventions used by the manual | none: notation explains how the manual is written, not source-language behavior |
| 01-overview | A taste | In-place array operations, exactly-once place evaluation, and record alias visibility | `native/t39_incdec_opassign.y`, `native/t40_array_ops.y`, `comprehensive: dot-assign: visible through an alias` |
| 02-lexical | Lexical structure | Byte-oriented scanning and ASCII token grammar | `native/t68_splice_scan.y`, `native/t74_lexical_operators.y`, `native/t25_radix.y` |
| 02-lexical | Source text | User-source positions survive import/embed splicing | `native/e14_prelude_lineno.y`, `native/e57_embed_lines.y`, `native/t66_embed.y`, `native/e133_import_error_positions.y` |
| 02-lexical | Source text | CRLF source-line endings | none: LF-only fixtures cannot directly exercise CRLF source bytes |
| 02-lexical | Comments | Line and block comments separate tokens; comment-like string text stays literal | `native/t68_splice_scan.y`, `native/t74_lexical_operators.y` |
| 02-lexical | Identifiers and keywords | Underscored identifiers and contextual names | `native/t47_none_void.y`, `native/t50_unions_match.y`, `native/t55_parse_forms.y`, `native/t67_str_methods.y` |
| 02-lexical | Identifiers and keywords | Reserved y_ generated-code prefix | none: y_ is reserved for compiler-generated labels, not user-program behavior |
| 02-lexical | Literals | Decimal, radix, binary and hexadecimal integer spellings | `native/t25_radix.y` |
| 02-lexical | Literals | Float, boolean and none literal forms | `native/t28_floats.y`, `native/t34_sci_literals.y`, `native/t47_none_void.y` |
| 02-lexical | Literals | String, byte, character and format-string escapes | `native/t41_byte_strings.y`, `native/t45_byte_repr.y`, `native/t51_strings_slices.y`, `native/t69_fstrings.y` |
| 02-lexical | Operators and punctuation | Maximal munch for adjacent increment and arithmetic tokens | `native/t74_lexical_operators.y`, `native/t39_incdec_opassign.y` |
| 02-lexical | Operators and punctuation | Compound operators, range, cons and match punctuation | `native/t39_incdec_opassign.y`, `native/t43_spread_cons.y`, `native/t50_unions_match.y` |
| 03-grammar | Syntax | Grammar chapter heading | none: the heading introduces grammar forms exercised in the subsections below |
| 03-grammar | Structure and modules | Imports, exports, relative paths and namespaces | `native/t55_parse_forms.y`, `native/e20_badmodule.y` |
| 03-grammar | Structure and modules | Embed bytes and splice imported source in order | `native/t66_embed.y`, `native/t68_splice_scan.y`, `native/e57_embed_lines.y` |
| 03-grammar | Structure and modules | One namespace: a def replacing another file's is an error naming both; same-file and std redefinitions are allowed | `native/e132_duplicate_import_def.y`, `native/t134_import_namespace.y`, `native/t30_typeof_records.y` |
| 03-grammar | Declarations | let, const, def, type aliases and defaults | `native/t59_const.y`, `native/t49_defaults_tco.y`, `native/t50_unions_match.y`, `native/t63_optional_args.y` |
| 03-grammar | Declarations | Anonymous and immediately-bound function literals | `native/t26_closures.y`, `native/t29_blocks_iife.y` |
| 03-grammar | Types | Scalar, array, fixed-array, option, pointer, function, record and map type syntax | `native/t06_ptr.y`, `native/t16_option.y`, `native/t46_maps.y`, `native/t50_unions_match.y`, `native/t57_from_bytes_fixed.y` |
| 03-grammar | Statements | if/else, while, C-style for, range-for, foreach and return | `native/t03_while.y`, `native/t27_loops_slices.y`, `native/t55_parse_forms.y`, `loops: for: basic`, `loops: foreach: sum array`, `loops: range: 3..7` |
| 03-grammar | Statements | Blocks as expressions, trailing semicolons and bare return | `native/t29_blocks_iife.y`, `native/t47_none_void.y`, `native/t55_parse_forms.y`, `native/e31_semicolon_void.y` |
| 03-grammar | Expressions | Literals, arrays, records, maps, blocks, closures and f-strings | `native/t29_blocks_iife.y`, `native/t40_array_ops.y`, `native/t46_maps.y`, `native/t50_unions_match.y`, `native/t69_fstrings.y` |
| 03-grammar | Expressions | Calls, indexing, slicing, fields, unwrap and prefix/postfix forms | `native/t39_incdec_opassign.y`, `native/t47_none_void.y`, `native/t51_strings_slices.y`, `native/t67_str_methods.y` |
| 03-grammar | Operator precedence | Arithmetic precedence, associativity, parentheses and right-associative cons | `comprehensive: precedence: mul before add`, `comprehensive: precedence: left-assoc div`, `comprehensive: precedence: parens`, `loops: precedence: mixed`, `native/t43_spread_cons.y` |
| 03-grammar | Assignment forms | Name, index, slice, field and pointer places with compound/inc-dec forms | `native/t06_ptr.y`, `native/t39_incdec_opassign.y`, `native/t51_strings_slices.y`, `native/e89_slice_assignment.y` |
| 04-types | Types and static semantics | Fatal static checking and structural type errors | `native/e11_recfield.y`, `native/e21_hetero_append.y`, `native/e25_map_value_type.y` |
| 04-types | Scalar types | long, byte, bool, float and str values | `native/t01_arith.y`, `native/t05_cmp_bool.y`, `native/t07_str.y`, `native/t28_floats.y`, `native/t37_bytes.y` |
| 04-types | Arrays | Homogeneous heap/fixed arrays and element-type enforcement | `native/t37_bytes.y`, `native/t40_array_ops.y`, `native/t57_from_bytes_fixed.y`, `native/e21_hetero_append.y` |
| 04-types | Records | Structural shapes, field access and shape-hole annotations | `native/t21_records.y`, `native/t50_unions_match.y`, `native/t81_record_shape_hole.y`, `native/e11_recfield.y` |
| 04-types | Maps | Homogeneous map values, optional reads and hashable key types | `native/t46_maps.y`, `native/t76_map_key_types.y`, `native/t135_map_read_boxes.y`, `native/e25_map_value_type.y`, `native/e26_map_key_type.y` |
| 04-types | Options and pointers | none/some/unwrap, option equality by payload, and raw address/dereference operations | `native/t06_ptr.y`, `native/t16_option.y`, `native/t47_none_void.y`, `native/t62_byte_ptr.y`, `native/t136_structural_equality.y`, `native/e28_unwrap_non_option.y`, `native/e34_addr_of_array.y` |
| 04-types | Void | Void calls and disagreeing if arms used as statements | `native/t47_none_void.y`, `native/t48_ternary_void.y`, `native/e24_void_if_value.y`, `native/e31_semicolon_void.y` |
| 04-types | Functions | Typed parameters, inferred returns, recursion and first-class values | `native/t02_recursion.y`, `native/t04_funcs.y`, `native/t26_closures.y`, `native/e05_badcall.y` |
| 04-types | Annotations and inference | Unannotated parameters, inferred results (every `return` conforms to and converts into the inferred type; the first `return` decides when the tail is a `self` call) and annotated byte-array literals | `native/t22_noannot.y`, `native/t37_bytes.y`, `native/t50_unions_match.y`, `native/t63_optional_args.y`, `native/t133_inferred_returns.y`, `native/e131_inferred_return_mismatch.y` |
| 04-types | Conversions | byte-to-long and long-to-float widening; str accepted at a pointer position | `native/t28_floats.y`, `native/t37_bytes.y`, `native/t82_str_pointer_conversion.y` |
| 04-types | Conversions | Annotated long-to-byte masking and long/byte-to-float conversion at every store under a known type, including a `return` under an inferred result; record fields never convert | `native/t132_implicit_conversions.y`, `native/t133_inferred_returns.y`, `native/e130_record_field_conversion.y` |
| 04-types | Operator typing | Numeric, string and array operators; comparisons, equality and truthy logic | `native/t28_floats.y`, `native/t33_str_compare.y`, `native/t40_array_ops.y`, `native/t75_eval_order.y`, `native/t77_reference_identity.y` |
| 04-types | Compound assignment typing | Valid numeric/string/array forms and rejected array operators | `native/t39_incdec_opassign.y`, `native/t40_array_ops.y`, `native/e21_hetero_append.y`, `native/e22_array_opassign_ops.y`, `native/e74_array_operators.y` |
| 04-types | The poison law | Unknown types do not cascade from unannotated parameters | `native/t22_noannot.y` |
| 05-expressions | Expressions and evaluation | Strict left-to-right operand evaluation and exactly-once place evaluation | `native/t39_incdec_opassign.y`, `native/t75_eval_order.y` |
| 05-expressions | Numeric semantics | Signed division/remainder edges, modulo-2^64 wraparound, float arithmetic and exact float negation | `native/t28_floats.y`, `native/t32_signed_div.y`, `native/t83_integer_wrap.y`, `native/t137_float_negation.y` |
| 05-expressions | Logic | Short-circuiting and truthiness of non-bool operands | `native/t75_eval_order.y`, `comprehensive: and: right side not evaluated`, `comprehensive: or: right side not evaluated` |
| 05-expressions | Strings | Immutable concatenation, stringification and lexicographic comparison | `native/t28_floats.y`, `native/t33_str_compare.y`, `native/t69_fstrings.y`, `native/t77_reference_identity.y` |
| 05-expressions | Assignment | Assignment statements store through names and mutable places | `native/t39_incdec_opassign.y`, `native/t51_strings_slices.y`, `native/t59_const.y` |
| 05-expressions | Assignment | Assignment is a statement form: it cannot nest, and a block ending in one yields the stored value | `native/t131_assign_block_value.y`, `native/e129_assign_nested.y` |
| 05-expressions | Increment, decrement and compound assignment | Prefix/postfix values and exactly-once target evaluation | `native/t39_incdec_opassign.y`, `native/t40_array_ops.y` |
| 06-arrays | Arrays | Growable homogeneous arrays are reference values | `native/t15_dynarr.y`, `native/t37_bytes.y`, `native/t40_array_ops.y`, `native/e21_hetero_append.y` |
| 06-arrays | Structure: length and capacity | Observable length, growth across reallocations and bounds traps | `native/t13_arroob.y`, `native/t37_bytes.y`, `native/t60_arr_props.y` |
| 06-arrays | Operators | New-array +, one-element cons, in-place append/push/prepend and self-append | `native/t40_array_ops.y`, `native/t43_spread_cons.y`, `native/t61_arr_plus_nested.y`, `native/t64_arr_of_arr_share.y` |
| 06-arrays | Aliasing and visibility | Aliases observe mutation while + and copies leave operands unchanged | `native/t40_array_ops.y`, `native/t64_arr_of_arr_share.y`, `native/t77_reference_identity.y` |
| 06-arrays | Fixed arrays | Fixed length, slicing, bounds traps and rejected growth | `native/t37_bytes.y`, `native/t57_from_bytes_fixed.y`, `native/t79_fixed_array_bounds.y`, `native/e09_pushfixed.y` |
| 06-arrays | Slices | Half-open clamped slices, fresh results and slice assignment | `native/t27_loops_slices.y`, `native/t51_strings_slices.y`, `native/t52_slice_mismatch.y`, `native/t78_slice_copy.y`, `native/t80_slice_bounds.y` |
| 06-arrays | Byte strings | Packed byte arrays, slicing, repr and byte/string conversion | `native/t37_bytes.y`, `native/t41_byte_strings.y`, `native/t45_byte_repr.y`, `native/t57_from_bytes_fixed.y` |
| 06-arrays | Operators are the interface | += and *= replace mutator builtins; len/join/byte helpers use arrays | `native/t37_bytes.y`, `native/t40_array_ops.y`, `native/t67_str_methods.y`, `comprehensive: push is gone`, `comprehensive: prepend is gone` |
| 07-references | Records and maps | Static records and dynamic homogeneous maps use distinct keying | `native/t21_records.y`, `native/t46_maps.y` |
| 07-references | The value model | Scalar/string value behavior versus shared array, record and map references | `native/t40_array_ops.y`, `native/t46_maps.y`, `native/t77_reference_identity.y` |
| 07-references | Records | Fixed field shapes, shared field stores and static record spread | `native/t21_records.y`, `native/t43_spread_cons.y`, `native/t81_record_shape_hole.y`, `comprehensive: spread: two sources, later wins` |
| 07-references | Maps | String and non-string hash keys, insertion order, optional reads and stores | `native/t46_maps.y`, `native/t76_map_key_types.y`, `native/t135_map_read_boxes.y`, `native/e25_map_value_type.y`, `native/e26_map_key_type.y` |
| 07-references | Equality | Structural array and option equality at any depth (elements and payloads by their own `==`) versus record/map identity | `native/t27_loops_slices.y`, `native/t77_reference_identity.y`, `native/t136_structural_equality.y` |
| 07-references | Copying | Explicit array/slice copies and rebuilt records do not alias the source | `native/t40_array_ops.y`, `native/t77_reference_identity.y`, `native/t78_slice_copy.y` |
| 08-functions | Functions, closures, options, pointers | Functions/closures/options/pointers chapter heading | none: the heading introduces the detailed subsections below |
| 08-functions | Functions | Named recursion, self, first-class values and call checking | `native/t02_recursion.y`, `native/t26_closures.y`, `native/t30_typeof_records.y`, `native/e05_badcall.y` |
| 08-functions | Tail calls | Self-tail recursion runs at constant stack depth | `native/t42_tail_calls.y`, `native/t49_defaults_tco.y` |
| 08-functions | Closures | Captured cells are shared and loop iterations can capture fresh bindings | `native/t26_closures.y`, `native/t53_globals_closures.y`, `native/t54_capture_cells.y` |
| 08-functions | Options | some/none, is_some, unwrap and readline EOF | `native/t16_option.y`, `native/t18_unwrapnone.y`, `native/t35_readline.y`, `native/t47_none_void.y` |
| 08-functions | Void | Inferred/annotated void functions, bare returns only in an inferred void, and void calls as statements | `native/t47_none_void.y`, `native/t48_ternary_void.y`, `native/t133_inferred_returns.y`, `native/e24_void_if_value.y`, `native/e31_semicolon_void.y`, `native/e131_inferred_return_mismatch.y` |
| 08-functions | Pointers | Address locals/elements, dereference and reject whole-array addresses | `native/t06_ptr.y`, `native/t62_byte_ptr.y`, `native/t82_str_pointer_conversion.y`, `native/e34_addr_of_array.y` |
| 09-builtins | Builtins | Predeclared builtins called with checked outputs | `native/t67_str_methods.y`, `comprehensive: typeof: long`, `comprehensive: len: array` |
| 09-builtins | Sequences and text | len/range/join/split/search and byte-oriented string helpers | `native/t27_loops_slices.y`, `native/t56_join.y`, `native/t67_str_methods.y`, `comprehensive: split: comma` |
| 09-builtins | String methods | Trimming, padding, search/replace, case, lines and method-call rules | `native/t67_str_methods.y`, `native/e59_str_no_method.y`, `native/e60_str_method_arity.y`, `native/e63_str_length_call.y` |
| 09-builtins | Conversions | tostring, tonum and typeof output | `native/t30_typeof_records.y`, `native/t57_from_bytes_fixed.y`, `comprehensive: tonum: integer string`, `comprehensive: tostring: float` |
| 09-builtins | Format specifications | Numeric/string format mini-language and format errors | `native/t69_fstrings.y`, `native/e68_fstr_bad_spec.y`, `native/e69_fstr_spec_type.y` |
| 09-builtins | Binary data | bytes/from_bytes and binary-safe packed byte arrays | `native/t37_bytes.y`, `native/t41_byte_strings.y`, `native/t57_from_bytes_fixed.y` |
| 09-builtins | Options | some/is_some/unwrap and postfix unwrap | `native/t16_option.y`, `native/t18_unwrapnone.y`, `native/t47_none_void.y` |
| 09-builtins | Input/output and the environment | stdin/EOF, files, argv, syscalls, exec and process exit | `native/t08_syscall.y`, `native/t10_filewrite.y`, `native/t20_files_argv.y`, `native/t35_readline.y`, `native/t38_exec.y`, `native/t58_readline_exec.y`, `sh/test_stdin_eof.sh` |
| 09-builtins | Pointers | Pointer-address conversion and byte-pointer operations | `native/t06_ptr.y`, `native/t62_byte_ptr.y`, `native/t82_str_pointer_conversion.y` |
| 10-errors | Errors and diagnostics | Errors chapter heading | none: compile-time, runtime and exit behavior are detailed below |
| 10-errors | Compile time | Fatal rejection with source-positioned diagnostics | `native/e02_undef.y`, `native/e21_hetero_append.y`, `native/e39_missing_semicolon.y`, `native/e41_import_missing.y` |
| 10-errors | Run time | Division, heap/fixed bounds, unwrap and slice-assignment traps | `native/t09_divzero.y`, `native/t13_arroob.y`, `native/t18_unwrapnone.y`, `native/t52_slice_mismatch.y`, `native/t79_fixed_array_bounds.y`, `native/t80_slice_bounds.y` |
| 10-errors | Run time | Missing dynamic record field trap | none: record fields are statically shape-checked before code generation |
| 10-errors | Run time | Match with no matching arm | none: non-exhaustive matches are rejected during static checking |
| 10-errors | Run time | Out-of-memory and unbounded non-tail recursion | none: exhausting memory or the stack guard is unsafe and nondeterministic |
| 10-errors | Exit status | Falling off, explicit exit and trapped programs' statuses | `native/t09_divzero.y`, `native/t13_arroob.y`, `native/t38_exec.y`, `native/t80_slice_bounds.y` |
| 10-errors | Reproducibility | Deterministic cross-compiler binaries and self-compiler fixpoint | `sh/test_port.sh`, `sh/test_fixpoint.sh` |

## Untested diagnostics

Diagnostic sites no test can reach, or whose message has no constant text
to look for. A row names the source file and a fragment of the site's code
line; a fragment that no longer matches an untested site fails the suite,
so the list cannot rot.

| Source | Code | Why |
|---|---|---|
| `src/y/parser.y` | `msg: v, line: ln` | Re-raises a lexer error token as a parse error; the lexer's messages are checked at their own sites. |
| `src/y/parser.y` | `msg: t.msg` | Re-raises a type-syntax error (`terr`) as an expression error; the `terr` site is checked. |
| `src/y/types.y` | `fail(st, node.msg` | The checker reporting a parser error node; the parser's sites are checked. |
| `src/y/types.y` | `fail(st, fterr` | Reports the call-target error chosen just above; each `fterr = "..."` site is checked. |
| `src/y/types.y` | `internal: params/ptypes length mismatch` | An internal consistency check: the parser appends a parameter's name and its type in the same loop iteration, so the two lists always match. |
| `src/y/types.y` | `is not defined on arrays (only` | `typeof_arith_arr` is only called from the `op == "+"` arm of `typeof_arith`; `-` `*` `/` `%` on an array fail as non-numeric operands instead. |
| `src/y/types.y` | `operator '" + op + "' is unsupported in native mode` | The parser builds a `bin` node only for an operator `op_prec` knows, and the checker's operator table handles every one of them; the `bin` nodes the parser and emitter synthesize use only `+` `==` `&&` `<` and the compound-assignment operators. |
| `src/y/types.y` | `is not a supported expression form` | Every expression node the parser builds has an arm in `typeof_expr`; `optarg` (optional-parameter metadata) is replaced with `none`/`some(...)` by `rn_fill_defaults` before checking. |
| `src/y/ycc.y` | `"error: assemble: "` | The assembler only reads the emitter's output, so a bad line is a compiler bug, not something a program can cause. |
