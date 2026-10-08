#!/bin/bash
# Comprehensive test suite for the Y language: every feature group below runs
# its snippet through BOTH compilers — the reference compiler (-q through the
# shim) and the C copy — and the expected text must appear on both sides.
# Usage: ./test/sh/test_comprehensive.sh   (YSHARD=K/N: one shard, lib.sh)

source "$(dirname "$0")/lib.sh"   # ROOT, YBOOT, YTIMEOUT_SCALE, PASS/FAIL, colors

VM_TO=$(( 10 * YTIMEOUT_SCALE ))    # compile + run, reference side
CC_TO=$(( 60 * YTIMEOUT_SCALE ))    # compile, C-copy side
RUN_TO=10                           # run the produced binary (never sanitized)

# Test helper: run code through both compilers and require the expected text
# on both sides. A compile failure IS the C copy's output, so the same helper
# covers the error-message tests.
run_test() {
    next_case || return 0
    local name="$1"
    local code="$2"
    local expected="$3"

    local tmpfile binfile vm_out vm_exit compile_out bin_out bin_exit
    tmpfile=$(mktemp -t ycomp_src_XXXXXX.y)
    binfile=$(mktemp -t ycomp_bin_XXXXXX)
    echo "$code" > "$tmpfile"

    # Reference side (quiet: only program output)
    vm_out=$(timeout "$VM_TO" "$YBOOT" -q "$tmpfile" </dev/null 2>&1)
    vm_exit=$?

    # C copy: compile, then run what it produced
    compile_out=$(timeout "$CC_TO" "$YBOOT" --compile "$tmpfile" -o "$binfile" </dev/null 2>&1)
    if [ $? -ne 0 ]; then
        bin_out="$compile_out"
        bin_exit=1
    else
        bin_out=$(run_bin "$RUN_TO" "$binfile" </dev/null 2>&1)
        bin_exit=$?
    fi

    rm -f "$tmpfile" "$binfile"

    local vm_ok=0
    local bin_ok=0

    if echo "$vm_out" | grep -qF -- "$expected"; then vm_ok=1; fi
    if echo "$bin_out" | grep -qF -- "$expected"; then bin_ok=1; fi

    if [ $vm_ok -eq 1 ] && [ $bin_ok -eq 1 ]; then
        pass "$name"
    else
        echo -e "${RED}FAIL${NC} $name"
        [ $vm_ok -eq 0 ] && echo "  REF missing: $expected (got: $vm_out)"
        [ $bin_ok -eq 0 ] && echo "  CPY missing: $expected (got: $bin_out)"
        FAIL=$((FAIL + 1))
    fi
}

# The empty program must print NOTHING and exit 0 on both sides. run_test
# accepts a text match, and the empty expected value matches any output at
# all, so this one case needs an exact comparison.
silent_test() {
    next_case || return 0
    local name="$1"
    local code="$2"

    local tmpfile binfile vm_out vm_exit bin_out bin_exit
    tmpfile=$(mktemp -t ycomp_src_XXXXXX.y)
    binfile=$(mktemp -t ycomp_bin_XXXXXX)
    echo "$code" > "$tmpfile"

    vm_out=$(timeout "$VM_TO" "$YBOOT" -q "$tmpfile" </dev/null 2>&1)
    vm_exit=$?
    if timeout "$CC_TO" "$YBOOT" --compile "$tmpfile" -o "$binfile" </dev/null >/dev/null 2>&1; then
        bin_out=$(run_bin "$RUN_TO" "$binfile" </dev/null 2>&1)
        bin_exit=$?
    else
        bin_out="(compilation failed)"
        bin_exit=1
    fi

    rm -f "$tmpfile" "$binfile"

    if [ $vm_exit -eq 0 ] && [ $bin_exit -eq 0 ] && [ -z "$vm_out" ] && [ -z "$bin_out" ]; then
        pass "$name"
    else
        echo -e "${RED}FAIL${NC} $name"
        echo "  REF(ec=$vm_exit): '$vm_out'"
        echo "  CPY(ec=$bin_exit): '$bin_out'"
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════"
echo "  Y compiler comprehensive test suite"
echo "═══════════════════════════════════════════"
echo ""

# ── Builtins: typeof ──
echo "── Builtins: typeof ──"
run_test "typeof: long" 'print(typeof(42));' 'long'
run_test "typeof: float" 'print(typeof(3.14));' 'float'
run_test "typeof: str" 'print(typeof("hi"));' 'str'
run_test "typeof: bool" 'print(typeof(true));' 'bool'
run_test "typeof: none" 'print(typeof(none));' 'none'
run_test "typeof: option" 'let o: long? = some(1); print(typeof(o));' 'long?'
run_test "typeof: array" 'print(typeof([1,2]));' '[long]'
# The spelling is the one a diagnostic gives the same type (m16): types.y has
# one renderer, so `typeof` and "expected { a: long }" cannot drift apart.
run_test "typeof: record" 'print(typeof({a:1}));' '{ a: long }'
run_test "typeof: function" 'def f(x: long) -> long { x }; print(typeof(f));' '(long) -> long'
run_test "typeof: nested function" 'def g(f: (long) -> long) -> long { f(1) }; print(typeof(g));' '((long) -> long) -> long'
run_test "typeof: fixed array" 'let a: [long; 2] = [1,2]; print(typeof(a));' '[long; 2]'
run_test "typeof: mutex" 'let m = mutex(); print(typeof(m));' 'mutex'

# ── Builtins: tostring ──
echo ""
echo "── Builtins: tostring ──"
run_test "tostring: long" 'print(tostring(42));' '42'
run_test "tostring: float" 'print(tostring(3.14));' '3.140000'
run_test "tostring: bool" 'print(tostring(true));' 'true'
run_test "tostring: none" 'print(tostring(none));' 'none'
run_test "tostring: array" 'print(tostring([1,2]));' '[1, 2]'
run_test "tostring: map" 'print(tostring({a:1}));' '{a: 1}'

# ── Builtins: tolong ──
echo ""
echo "── Builtins: tolong ──"
run_test "tolong: integer string" 'print(tolong("123"));' '123'
run_test "tolong: float string is not a whole number" 'print(tolong("3.14"));' 'none'
run_test "tolong: negative" 'print(tolong("-42"));' '-42'
# print separates its arguments with a space only when they are strings, so
# two longs come out as "2-2": the point here is that -2.75 gives -2 and not
# -3, which is what separates truncation from floor.
run_test "tolong: float truncates toward zero" 'print(tolong(2.75), tolong(-2.75));' '2-2'
run_test "tolong: method form" 'print("17".tolong());' '17'

# ── Builtins: tofloat ──
echo ""
echo "── Builtins: tofloat ──"
run_test "tofloat: fraction" 'print(tofloat("3.14"));' '3.140000'
run_test "tofloat: negative" 'print(tofloat("-0.5"));' '-0.500000'
run_test "tofloat: long widens" 'print(tofloat(7));' '7.000000'
run_test "tofloat: method form" 'print("2.5".tofloat());' '2.500000'
# An exponent is not read: the scan stops at the 'e', the same way tolong
# stops at the '.' -- one tolerance for both, so a value cannot behave
# differently depending on which conversion it went through.
run_test "tofloat: no exponent is not read" 'print(tofloat("1e9"));' 'none'

# ── Builtins: len ──
echo ""
echo "── Builtins: len ──"
run_test "len: string" 'print(len("hello"));' '5'
run_test "len: array" 'print(len([1,2,3]));' '3'
run_test "len: empty array" 'print(len([]));' '0'
run_test "len: empty string" 'print(len(""));' '0'

# ── Builtins: ord/chr ──
echo ""
echo "── Builtins: ord/chr ──"
run_test "ord: A" 'print(ord("A"));' '65'
run_test "ord: a" 'print(ord("a"));' '97'
run_test "chr: 65" 'print(chr(65));' 'A'
run_test "chr: 97" 'print(chr(97));' 'a'

# ── String slicing ──
echo ""
echo "── String slicing ──"
run_test "slice: middle" 'print("hello"[1:4]);' 'ell'
run_test "slice: from start" 'print("hello"[:2]);' 'he'
run_test "slice: to end" 'print("hello"[3:]);' 'lo'
run_test "slice: empty" 'print("hello"[2:2]);' ''

# ── Builtins: split/join ──
echo ""
echo "── Builtins: split/join ──"
run_test "split: comma" 'print(split("a,b,c", ","));' '[a, b, c]'
run_test "split: space" 'print(split("x y z", " "));' '[x, y, z]'
run_test "join: dash" 'print(join(["x","y","z"], "-"));' 'x-y-z'
run_test "join: empty sep" 'print(join(["a","b","c"], ""));' 'abc'

# ── Builtins: trim ──
echo ""
echo "── Builtins: trim ──"
run_test "trim: spaces" 'print(trim("  hi  "));' 'hi'
run_test "trim: tabs" 'print(trim("\t\thello\t\t"));' 'hello'
run_test "trim: no whitespace" 'print(trim("clean"));' 'clean'

# ── Builtins: index_of/last_index_of ──
echo ""
echo "── Builtins: index_of/last_index_of ──"
run_test "index_of: found" 'print(index_of("hello", "ll"));' '2'
run_test "index_of: not found" 'print(index_of("hello", "xyz"));' '-1'
run_test "last_index_of: found" 'print(last_index_of("hello", "l"));' '3'
run_test "last_index_of: not found" 'print(last_index_of("hello", "xyz"));' '-1'

# ── Removed builtins: must STAY gone (they were language functions once) ──
echo ""
echo "── Removed builtins ──"
run_test "push is gone" 'let a = [1,2]; print(push(a, 3));' "undefined function 'push'"
run_test "prepend is gone" 'let a = [1,2]; print(prepend(0, a));' "undefined function 'prepend'"

# ── Builtins: map_get/map_set ──
echo ""
echo "── Builtins: map_get/map_set ──"
# Maps (dynamic) are a separate type from records (static structs):
# {K: V} with a hashable key type K and one homogeneous value type V.
# Quoted keys make a map literal; record keys are identifiers. Keying is
# symbolic: a.key for records, a['key'] for maps. (map_get/map_set/push
# are gone -- symbol ops replace them.)
run_test "map: get existing" 'let m = {"a": 1}; print(m["a"]);' '1'
run_test "map: get missing" 'let m = {"a": 1}; print(m["b"]);' 'none'
run_test "map: set overwrite" 'let m = {"a": 1}; m["a"] = 2; print(m["a"]);' '2'
run_test "map: set new key" 'let m = {"a": 1}; m["b"] = 3; print(m["b"]);' '3'
run_test "map: homogeneous values" 'let m = {"a": 1, "b": 2}; print(m["b"]);' '2'
run_test "map_get is gone" 'let m = {"a": 1}; print(map_get(m, "a"));' "undefined function 'map_get'"
run_test "map_set is gone" 'let m = {"a": 1}; map_set(m, "a", 2);' "undefined function 'map_set'"

# ── Records: spread ──
echo ""
echo "── Records: spread ──"
run_test "spread: after explicit keys" 'let b = {x: 1, y: 2}; print({a: 0, ...b});' '{a: 0, x: 1, y: 2}'
run_test "spread: two sources, later wins" 'let b = {x: 1, y: 2}; let c = {y: 9, z: 3}; print({...b, ...c});' '{x: 1, y: 9, z: 3}'
run_test "spread: explicit key after spread wins" 'let b = {x: 1, y: 2}; print({...b, y: 100});' '{x: 1, y: 100}'
run_test "spread: copy" 'let b = {x: 1, y: 2}; print({...b});' '{x: 1, y: 2}'
run_test "spread: source untouched" 'let b = {x: 1}; let d = {...b, w: 4}; print(b);' '{x: 1}'
run_test "spread: field read from result" 'let b = {x: 1}; let d = {...b, w: 4}; print(d.w);' '4'

# ── Records: field assignment ──
echo ""
echo "── Records: field assignment ──"
run_test "dot-assign: overwrite" 'let s = {a: 1, b: 2}; s.a = 9; print(s.a);' '9'
run_test "dot-assign: leaves others" 'let s = {a: 1, b: 2}; s.a = 9; print(s.b);' '2'
# A record's shape is fixed at compile time (struct layout): writing a
# field the shape does not have is a compile error.
run_test "dot-assign: new key is rejected" 'let s = {a: 1}; s.c = 7; print(s.c);' "record has no field 'c'"
run_test "dot-assign: string key form is map-only" 'let r = {k: "v"}; r["k"] = "w"; print(r.k);' "cannot index { k: str } (only arrays and maps)"
run_test "index-assign: map string key" 'let m = {"k": "v"}; m["k"] = "w"; print(m["k"]!);' 'w'
run_test "dot-assign: visible through an alias" 'let n = {inner: {n: 1}}; let t = n.inner; t.n = 5; print(n.inner.n);' '5'
run_test "index-assign still works" 'let a = [1,2,3]; a[1] = 20; print(a);' '[1, 20, 3]'

# ── Postfix: field access binds tighter than unary and index ──
echo ""
echo "── Postfix: field access ──"
run_test "dot then index" 'let m = { xs: [10, 20, 30] }; print(m.xs[1]);' '20'
run_test "dot then index in arithmetic" 'let m = { xs: [10, 20, 30] }; print(m.xs[0] + m.xs[2]);' '40'
run_test "not of a field" 'let m = { flag: false }; print(!m.flag);' 'true'
run_test "negate a field" 'let m = { n: 5 }; print(-m.n);' '-5'
run_test "index then dot" 'let arr = [{v: 7}, {v: 8}]; print(arr[1].v);' '8'
run_test "nested fields" 'let n = { inner: { deep: 5 } }; print(n.inner.deep);' '5'
run_test "field of a string" 'let m = { name: "hi" }; print(m.name);' 'hi'

# ── Operators: short-circuit logic ──
echo ""
echo "── Operators: short-circuit logic ──"
run_test "and: truth table TT" 'print(true && true);' 'true'
run_test "and: truth table TF" 'print(true && false);' 'false'
run_test "or: truth table FT" 'print(false || true);' 'true'
run_test "or: truth table FF" 'print(false || false);' 'false'
run_test "and: right side not evaluated" 'def boom() -> bool { print(999); true }; if (false && boom()) { print("bad"); } else { print("ok"); };' 'ok'
run_test "or: right side not evaluated" 'def boom() -> bool { print(999); true }; if (true || boom()) { print("ok"); };' 'ok'
run_test "and: guards an out-of-range index" 'let a = [1,2]; let i = 5; if (i < len(a) && a[i] == 1) { print("bad"); } else { print("guarded"); };' 'guarded'
run_test "or: guards an out-of-range index" 'let a = [1,2]; let i = 5; if (i >= len(a) || a[i] == 1) { print("guarded"); };' 'guarded'

# ── Operators: array concat and compound assignment ──
echo ""
echo "── Operators: array concat and compound assignment ──"
run_test "array + array" 'let a = [1,2]; let b = [3,4]; print(a + b);' '[1, 2, 3, 4]'
run_test "array + element" 'let a = [1,2]; print(a + 9);' '[1, 2, 9]'
run_test "element + array" 'let a = [1,2]; print(0 + a);' '[0, 1, 2]'
run_test "array literals on both sides" 'print([1,2] + [3]);' '[1, 2, 3]'
run_test "array + leaves operands alone" 'let a = [1,2]; let b = a + 3; print(a);' '[1, 2]'
run_test "array + with strings stays an array" 'let s = ["x"]; print(s + "y");' '[x, y]'
run_test "empty array + element" 'print([] + 1);' '[1]'
run_test "array + empty array" 'let a = [1]; print(a + []);' '[1]'
run_test "compound: array append" 'let a = [1,2]; a += 3; print(a);' '[1, 2, 3]'
run_test "compound: array concat" 'let a = [1]; a += [2,3]; print(a);' '[1, 2, 3]'
run_test "compound: numeric add" 'let n = 10; n += 5; print(n);' '15'
run_test "compound: numeric sub" 'let n = 10; n -= 3; print(n);' '7'
run_test "compound: numeric mul" 'let n = 10; n *= 3; print(n);' '30'
run_test "compound: numeric div" 'let n = 12; n /= 4; print(n);' '3'
run_test "compound: string append" 'let s = "ab"; s += "cd"; print(s);' 'abcd'
run_test "compound: in a loop" 'let i = 0; while (i < 3) { i += 1; }; print(i);' '3'

# ── Operators: arithmetic ──
echo ""
echo "── Operators: arithmetic ──"
run_test "add" 'print(2 + 3);' '5'
run_test "subtract" 'print(10 - 4);' '6'
run_test "multiply" 'print(3 * 4);' '12'
run_test "divide" 'print(20 / 4);' '5'
run_test "modulo" 'print(10 % 3);' '1'
run_test "precedence: mul before add" 'print(2 + 3 * 4);' '14'
run_test "precedence: parens" 'print((2 + 3) * 4);' '20'
run_test "precedence: left-assoc div" 'print(100 / 10 / 2);' '5'
run_test "precedence: left-assoc sub" 'print(10 - 2 - 3);' '5'
# Signed division: operands are NOT wrapped through unsigned (an older
# engine did that to dodge signed-overflow UB in + - *, which silently turned
# / and % into UNSIGNED division -- 7 / -2 gave 0 and -7 / 2 gave
# 9223372036854775804). These cases pin the current, signed result.
run_test "divide: negative divisor" 'print(7 / -2);' '-3'
run_test "divide: negative dividend" 'print(-7 / 2);' '-3'
run_test "divide: both negative" 'print(-7 / -2);' '3'
run_test "modulo: negative divisor" 'print(7 % -2);' '1'
run_test "modulo: negative dividend" 'print(-7 % 2);' '-1'
# LONG_MIN / -1 overflows: idiv raises #DE, so both compilers wrap to
# LONG_MIN (and LONG_MIN % -1 is 0) instead of trapping.
run_test "divide: LONG_MIN by -1" 'let mn = -9223372036854775807 - 1; print(mn / -1);' '-9223372036854775808'
run_test "modulo: LONG_MIN by -1" 'let mn = -9223372036854775807 - 1; print(mn % -1);' '0'

# ── Operators: comparison ──
echo ""
echo "── Operators: comparison ──"
run_test "less than: true" 'print(1 < 2);' 'true'
run_test "less than: false" 'print(2 < 1);' 'false'
run_test "greater than: true" 'print(3 > 2);' 'true'
run_test "greater than: false" 'print(2 > 3);' 'false'
run_test "less or equal: true" 'print(2 <= 2);' 'true'
run_test "greater or equal: true" 'print(3 >= 3);' 'true'
# Lexicographic string ordering (both compilers; strcmp semantics).
run_test "str less than: true" 'print("a" < "b");' 'true'
run_test "str less than: false" 'print("b" < "a");' 'false'
run_test "str prefix is smaller" 'print("ab" < "abc");' 'true'
run_test "str empty is smallest" 'print("" < "a");' 'true'
run_test "str case: upper before lower" 'print("Z" < "a");' 'true'
run_test "str greater or equal" 'print("apple" >= "apple");' 'true'

# ── byte type and byte/string conversion ──
echo ""
echo "── byte type and byte/string conversion ──"
run_test "bytes: length" 'print(len(bytes("Hello")));' '5'
run_test "bytes: first element" 'let b = bytes("Hello"); print(b[0]);' '72'
run_test "bytes: round trip" 'print(from_bytes(bytes("round trip")));' 'round trip'
run_test "bytes: empty string" 'print(len(bytes("")));' '0'
run_test "from_bytes: literal" 'let b: [byte] = [104, 105]; print(from_bytes(b));' 'hi'
run_test "byte: annotated array literal" 'let b: [byte] = [1, 2, 3]; print(tostring(b));' "b'\\x01\\x02\\x03'"
run_test "byte: widens to long" 'let b: [byte] = [41]; let n = b[0] + 1; print(n);' '42'
run_test "byte: unsigned above 127" 'let b: [byte] = [200]; print(b[0]);' '200'
run_test "byte: push and index" 'let b: [byte] = []; b += 65; b += 66; print(from_bytes(b));' 'AB'
run_test "byte: slice" 'let b: [byte] = [97, 98, 99, 100]; print(from_bytes(b[1:3]));' 'bc'
run_test "tostring: array of long" 'print(tostring([1, 2, 3]));' '[1, 2, 3]'
run_test "tostring: array of str" 'print(tostring(["a", "b"]));' '[a, b]'
run_test "tostring: nested array" 'print(tostring([[1, 2], [3]]));' '[[1, 2], [3]]'
run_test "equal: true" 'print(5 == 5);' 'true'
run_test "equal: false" 'print(5 == 6);' 'false'
run_test "not equal: true" 'print(5 != 6);' 'true'
run_test "not equal: false" 'print(5 != 5);' 'false'

# ── Operators: logical ──
echo ""
echo "── Operators: logical ──"
run_test "and: true" 'print(true && true);' 'true'
run_test "and: false" 'print(true && false);' 'false'
run_test "or: true" 'print(false || true);' 'true'
run_test "or: false" 'print(false || false);' 'false'
run_test "not: true" 'print(!false);' 'true'
run_test "not: false" 'print(!true);' 'false'
run_test "complex logical" 'print(1 < 2 && 3 > 2 || false);' 'true'

# ── Operators: unary ──
echo ""
echo "── Operators: unary ──"
run_test "unary minus" 'print(-5);' '-5'
run_test "unary minus expr" 'print(-(2 + 3));' '-5'
run_test "double negative" 'print(-(-5));' '5'
run_test "prefix -- is decrement" 'let x = 5; --x; print(x);' '4'

# ── Operators: cons ──
echo ""
echo "── Operators: cons ──"
run_test "cons: to array" 'print(0 :: [1,2,3]);' '[0, 1, 2, 3]'
run_test "cons: to empty" 'print(42 :: []);' '[42]'
run_test "cons: chained" 'print(1 :: 2 :: [3]);' '[1, 2, 3]'

# ── Operators: slice ──
echo ""
echo "── Operators: slice ──"
# A postfix chain straight off an array literal parses fine: the parser runs
# parse_primary (which builds the literal) and then its own postfix loop, so
# [1,2,3][0:2] slices the literal itself — no binding needed.
run_test "slice: full" 'let a = [1,2,3,4]; print(a[0:4]);' '[1, 2, 3, 4]'
run_test "slice: literal operand" 'print([1,2,3][0:2]);' '[1, 2]'
run_test "index: literal operand" 'print([1,2,3][1]);' '2'
run_test "slice: partial" 'let a = [1,2,3,4]; print(a[1:3]);' '[2, 3]'
run_test "slice: from start" 'let a = [1,2,3,4]; print(a[:2]);' '[1, 2]'
run_test "slice: to end" 'let a = [1,2,3,4]; print(a[2:]);' '[3, 4]'
run_test "slice: all" 'let a = [1,2,3,4]; print(a[:]);' '[1, 2, 3, 4]'
run_test "slice: empty result" 'let a = [1,2,3]; print(a[2:1]);' '[]'

# ── Literals: numeric formats ──
echo ""
echo "── Literals: numeric formats ──"
run_test "hex literal" 'print(0xff);' '255'
run_test "hex literal: uppercase" 'print(0xFFAB);' '65451'
run_test "hex literal: mixed case prefix" 'print(0XFF);' '255'
run_test "binary literal" 'print(0b101);' '5'
run_test "binary literal: uppercase prefix" 'print(0B1111);' '15'
run_test "radix: arithmetic" 'print(0x10 + 0b10);' '18'
run_test "radix: underscores" 'print(0xdead_beef);' '3735928559'
run_test "radix: negative" 'print(-0x10);' '-16'
run_test "exponent: integer mantissa" 'print(1e3);' '1000.000000'
run_test "exponent: float mantissa" 'print(1.5e2);' '150.000000'
run_test "exponent: negative exponent" 'print(2.5e-2);' '0.025000'
run_test "decimal still works" 'print(42);' '42'
run_test "float still works" 'print(1.25);' '1.250000'

# ── Functions: basic ──
echo ""
echo "── Functions: basic ──"
run_test "function: simple" 'def add(a: long, b: long) -> long { a + b }; print(add(2, 3));' '5'
run_test "function: no params" 'def answer() -> long { 42 }; print(answer());' '42'
run_test "function: string return" 'def greet(name: str) -> str { "Hello " + name }; print(greet("World"));' 'Hello World'

# ── Functions: recursion ──
echo ""
echo "── Functions: recursion ──"
run_test "recursion: factorial" 'def fact(n: long) -> long { if (n <= 1) { 1 } else { n * self(n - 1) } }; print(fact(5));' '120'
run_test "recursion: fibonacci" 'def fib(n: long) -> long { if (n < 2) { n } else { self(n-1) + self(n-2) } }; print(fib(10));' '55'
run_test "recursion: countdown" 'def count(n: long) -> str { if (n <= 0) { "done" } else { tostring(n) + " " + self(n-1) } }; print(count(3));' '3 2 1 done'
run_test "self: still the recursion handle" 'def fact(n: long) -> long { if (n <= 1) { 1 } else { n * self(n - 1) } }; print(fact(5));' '120'
run_test "self: usable as a parameter name" 'def f(self: long) -> long { self + 1 }; print(f(41));' '42'
run_test "self: usable as a local name" 'def g() -> long { let self = 5; self * 2 }; print(g());' '10'

# ── Functions: early return ──
echo ""
echo "── Functions: early return ──"
run_test "return: guard clause" 'def f(n: long) -> long { if (n < 0) { return 0 - n; }; n * 2 }; print(f(-5));' '5'
run_test "return: falls through" 'def f(n: long) -> long { if (n < 0) { return 0 - n; }; n * 2 }; print(f(3));' '6'
run_test "return: skips rest of body" 'def f() -> long { return 1; 999 }; print(f());' '1'
run_test "return: out of a while loop" 'def f(xs: [long]) -> long { let i = 0; while (i < len(xs)) { if (xs[i] > 10) { return xs[i]; }; i = i + 1; }; 0 - 1 }; print(f([1, 2, 42, 7]));' '42'
run_test "return: loop finishes without returning" 'def f(xs: [long]) -> long { let i = 0; while (i < len(xs)) { if (xs[i] > 10) { return xs[i]; }; i = i + 1; }; 0 - 1 }; print(f([1, 2]));' '-1'
run_test "return: bare return makes a void def" 'def f() { return; }; print(f());' 'got void'
run_test "return: bare return in a typed def" 'def f() -> long { return; }; print(f());' "'return': expected long, got void"
run_test "return: -> void discards the tail" 'def f(x: long) -> void { print(x); x }; f(4);' '4'
run_test "return: value in a void def" 'def f() -> void { return 1; };' "'return': expected void, got long"
run_test "return: nested in inner function" 'def outer() -> long { def inner(n: long) -> long { if (n > 0) { return 7; }; 0 }; inner(1) + 1 }; print(outer());' '8'

# ── Void: disagreeing if arms ──
# When the arms of an if/else disagree on a type, the whole if is void: a
# statement, legal on its own, rejected wherever a value is needed.
echo ""
echo "── Void: disagreeing if arms ──"
run_test "void-if: legal as a statement" 'if (true) { 1 } else { "a" }; print(2);' '2'
run_test "void-if: agreeing arms keep their type" 'let x = if (false) { 1 } else { 2 }; print(x);' '2'
run_test "void-if: cannot be bound" 'let x = if (true) { 1 } else { "a" };' "cannot bind a void value to 'x'"
run_test "void-if: cannot be printed" 'print(if (true) { 1 } else { "a" });' 'got void'
run_test "void-if: cannot be an argument" 'def f(v) { v }; f(if (true) { 1 } else { "a" });' "'f' arg 0: cannot pass a void value"
run_test "void-if: cannot be returned as a value" 'def f() -> long { if (true) { 1 } else { "a" } };' "'f' body: expected long, got void"

# ── Options: none and postfix ! ──
echo ""
echo "── Options: none and postfix ! ──"
run_test "none: prints as none" 'let a: long? = none; print(a);' 'none'
run_test "none: is-none check" 'let a: long? = none; print(a == none);' 'true'
run_test "none: some is not none" 'let a: long? = some(0); print(a == none);' 'false'
run_test "none: a plain value is not an option" 'let a: long? = 5;' "expected long?, got long"
run_test "none: str is not optional" 'let s = "x"; print(s == none);' "'==' compares str with none"
run_test "null: is gone" 'let x = null;' "undefined variable 'null'"
run_test "unwrap-!: some value" 'let a: long? = some(41); print(a! + 1);' '42'
run_test "unwrap-!: same as unwrap()" 'let a: str? = some("hi"); print(a! == unwrap(a));' 'true'
run_test "unwrap-!: on a map read" 'let m = {"k": 7}; print(m["k"]! * 6);' '42'
run_test "unwrap-!: binds tighter than unary !" 'let b: bool? = some(false); print(!b!);' 'true'
run_test "unwrap-!: none traps" 'let a: long? = none; print(a!);' 'runtime error: unwrap of none'
run_test "unwrap-!: != still lexes" 'let a = 1; print(a != 2);' 'true'
run_test "unwrap-!: needs an option" 'let a = 1; print(a!);' 'unwrap needs an option'

# ── Functions: closures ──
echo ""
echo "── Functions: closures ──"
run_test "closure: capture" 'def outer() { let x = 10; def inner() { x + 5 }; inner() }; print(outer());' '15'
run_test "closure: counter" 'def make_counter() { let n = 0; def inc() { n = n + 1; n }; inc }; let c = make_counter(); c(); c(); print(c());' '3'

# ── Functions: higher-order ──
echo ""
echo "── Functions: higher-order ──"
run_test "HOF: map" 'def map(f: (long) -> long, xs: [long]) -> [long] { let r: [long] = []; foreach (x in xs) { r += f(x) }; r }; def double(x: long) { x * 2 }; print(map(double, [1,2,3]));' '[2, 4, 6]'
run_test "HOF: filter" 'def filter(p: (long) -> bool, xs: [long]) -> [long] { let r: [long] = []; foreach (x in xs) { if (p(x)) { r += x; 0; } else { 0; }; 0 }; r }; def is_even(x: long) { x % 2 == 0 }; print(filter(is_even, [1,2,3,4,5]));' '[2, 4]'
run_test "HOF: reduce" 'def reduce(f: (long, long) -> long, acc: long, xs: [long]) -> long { foreach (x in xs) { acc = f(acc, x) }; acc }; def add(a: long, b: long) { a + b }; print(reduce(add, 0, [1,2,3,4,5]));' '15'

# ── Functions: anonymous ──
echo ""
echo "── Functions: anonymous ──"
run_test "anonymous: immediate" 'print((def(x: long) { x * 2 })(5));' '10'
run_test "anonymous: as arg" 'def apply(f: (long) -> long, x: long) { f(x) }; print(apply(def(n: long) { n + 1 }, 10));' '11'

# ── Data types: arrays ──
echo ""
echo "── Data types: arrays ──"
run_test "array: literal" 'print([1, 2, 3]);' '[1, 2, 3]'
run_test "array: empty" 'print([]);' '[]'
run_test "array: index" 'let a = [10, 20, 30]; print(a[1]);' '20'
run_test "array: nested" 'let a = [[1,2], [3,4]]; print(a[1][0]);' '3'
run_test "array: mixed types is rejected" 'print([1, "two", true, none]);' "array element: expected long, got str" 

# ── Data types: maps ──
echo ""
echo "── Data types: maps ──"
run_test "map: literal" 'print({a: 1, b: 2});' '{a: 1, b: 2}'
run_test "map: empty" 'print({});' '{}'
run_test "map: dot access" 'let m = {x: 42}; print(m.x);' '42'
run_test "map: nested" 'let m = {a: {b: 1}}; print(m.a.b);' '1'
run_test "map: function value" 'let m = {f: def(x: long) { x * 2 }}; print(m.f(5));' '10'

# ── Data types: strings ──
echo ""
echo "── Data types: strings ──"
run_test "string: concat" 'print("Hello" + " " + "World");' 'Hello World'
run_test "string: with number" 'print("Value: " + tostring(42));' 'Value: 42'
run_test "string: escapes" 'print("Line1\nLine2");' 'Line1
Line2'
run_test "string: tab" 'print("Col1\tCol2");' 'Col1	Col2'
run_test "string: hex escape" 'print("\x41\x42\x43");' 'ABC'

# ── Control flow: if/else ──
echo ""
echo "── Control flow: if/else ──"
run_test "if: true branch" 'if (true) { print("yes"); };' 'yes'
run_test "if: false branch" 'if (false) { print("no"); } else { print("yes"); };' 'yes'
run_test "if-else chain" 'let x = 2; if (x == 1) { print("one"); } else if (x == 2) { print("two"); } else { print("other"); };' 'two'
run_test "if: nested" 'if (true) { if (false) { print("inner"); } else { print("outer"); } };' 'outer'

# ── Control flow: while ──
echo ""
echo "── Control flow: while ──"
run_test "while: counter" 'let i = 0; while (i < 5) { i = i + 1 }; print(i);' '5'
run_test "while: accumulator" 'let s = 0; let i = 1; while (i <= 10) { s = s + i; i = i + 1 }; print(s);' '55'
run_test "while: nested" 'let total = 0; let i = 0; while (i < 3) { let j = 0; while (j < 3) { total = total + 1; j = j + 1 }; i = i + 1 }; print(total);' '9'

# ── Control flow: for ──
echo ""
echo "── Control flow: for ──"
run_test "for: basic" 'let s = 0; for (let i = 0; i < 5; i = i + 1) { s = s + i }; print(s);' '10'
run_test "for: countdown" 'let s = ""; for (let i = 5; i > 0; i = i - 1) { s = s + tostring(i) }; print(s);' '54321'
run_test "for: nested" 'let s = 0; for (let i = 0; i < 3; i = i + 1) { for (let j = 0; j < 3; j = j + 1) { s = s + 1 } }; print(s);' '9'

# ── Control flow: foreach ──
echo ""
echo "── Control flow: foreach ──"
run_test "foreach: sum" 'let s = 0; foreach (x in [1,2,3,4,5]) { s = s + x }; print(s);' '15'
run_test "foreach: string concat" 'let r = ""; foreach (w in ["a", "b", "c"]) { r = r + w }; print(r);' 'abc'
run_test "foreach: nested" 'let s = 0; foreach (a in [1,2]) { foreach (b in [10,20]) { s = s + a * b } }; print(s);' '90'

# ── Control flow: for..in range ──
echo ""
echo "── Control flow: for..in range ──"
run_test "range: 0..5" 'let s = 0; for i in 0..5 { s = s + i }; print(s);' '10'
run_test "range: 3..7" 'let s = 0; for i in 3..7 { s = s + i }; print(s);' '18'
run_test "range: nested" 'let s = 0; for i in 0..3 { for j in 0..3 { s = s + i + j } }; print(s);' '18'

# ── Declarations ──
echo ""
echo "── Declarations ──"
run_test "let: basic" 'let x = 42; print(x);' '42'
run_test "let: reassign" 'let x = 1; x = 2; print(x);' '2'
run_test "const: basic" 'const x = 42; print(x);' '42'
run_test "def: function" 'def f() { 99 }; print(f());' '99'

# ── Edge cases ──
echo ""
echo "── Edge cases ──"
silent_test "empty program" ''
run_test "trailing comma: array" 'print([1, 2, 3,]);' '[1, 2, 3]'
run_test "trailing comma: map" 'print({a: 1, b: 2,});' '{a: 1, b: 2}'
run_test "nested structures" 'let data = {arr: [1, 2], val: 3}; let a = data.arr; print(a[1] + data.val);' '5'
run_test "deep nesting" 'let a = [[[[42]]]]; print(a[0][0][0][0]);' '42'

# ── Error cases ──
# A type/name error is a STATIC error: the checker rejects the file, the
# compiler prints "L:C: error: ..." and exits 1 without writing a binary.
# Both compilers must say it, so these cases match the diagnostic itself.
echo ""
echo "── Error cases ──"
run_test "undefined variable" 'print(undefined_var);' 'undefined_var'
run_test "type error: call non-function" 'let x = 42; x();' "is not a function"
# An unterminated literal list is a syntax error, not a silently dropped
# expression: the parser plants an "err" node and the checker reports it.
run_test "unclosed paren is rejected" 'print((1 + 2);' "unexpected ';' (expected ',' or ')')"
run_test "unclosed bracket is rejected" 'let a = [1, 2; print(a);' "unexpected ';' (expected ',' or ']')"
# Arity is a STATIC error, reported by the type checker with the call's
# line:col ("'add' takes 2 args, got 1"); nothing is emitted, nothing runs.
# (It was a run-time check in the old engines, where a short call read the
# argument array past its end -- see test/y/native/e05_badcall.y.)
run_test "arity: too few args" 'def add(a: long, b: long) -> long { a + b }; print(add(1));' "takes 2 args, got 1"
run_test "arity: too many args" 'def one(a: long) -> long { a }; print(one(1, 2));' "takes 1 args, got 2"
run_test "arity: args to a no-arg function" 'def z() -> long { 7 }; print(z(1));' "takes 0 args, got 1" 

# ── Self-hosted compiler ──
# Lives in test/sh/test_ycc.sh (needs ./ycc); run via `make test` or
# ./test/sh/test_ycc.sh. Skipped here to avoid running it twice.
echo ""
echo "── Self-hosted compiler ──"
echo "  (see test/sh/test_ycc.sh)"

# ── Summary ──
echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} / $TOTAL total"
echo "═══════════════════════════════════════════"

[ $FAIL -eq 0 ] && exit 0 || exit 1
