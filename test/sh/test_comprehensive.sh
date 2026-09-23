#!/bin/bash
# Comprehensive test suite for the Y compiler
# Tests all language features, builtins, operators, and both VM/compiled modes
# Usage: ./test_comprehensive.sh

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
YBOOT="${YBOOT:-$ROOT/yboot}"  # overridable: make test-asan points this at yboot-asan

# A sanitized toolchain runs roughly 15x slower (see lib.sh).
YTIMEOUT_SCALE=1
case "$YBOOT" in
    *asan* | *msan* | *ubsan*) YTIMEOUT_SCALE=15 ;;
esac
VM_TO=$(( 10 * YTIMEOUT_SCALE ))

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Test helper: run code in both VM and compiled modes, compare outputs
run_test() {
    local name="$1"
    local code="$2"
    local expected="$3"

    tmpfile=$(mktemp /tmp/ytest_XXXXXX.y)
    binfile=$(mktemp /tmp/ytest_bin_XXXXXX)
    echo "$code" > "$tmpfile"

    # VM (quiet: only program output)
    vm_out=$(timeout $VM_TO $YBOOT -q "$tmpfile" 2>&1)
    vm_exit=$?

    # Compiled
    $YBOOT --compile "$tmpfile" -o "$binfile" >/dev/null 2>&1
    bin_out=$(timeout 10 "$binfile" 2>&1)
    bin_exit=$?

    rm -f "$tmpfile" "$binfile"

    vm_ok=0
    bin_ok=0

    if echo "$vm_out" | grep -qF -- "$expected"; then vm_ok=1; fi
    if echo "$bin_out" | grep -qF -- "$expected"; then bin_ok=1; fi

    if [ $vm_ok -eq 1 ] && [ $bin_ok -eq 1 ]; then
        echo -e "${GREEN}PASS${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} $name"
        [ $vm_ok -eq 0 ] && echo "  VM missing: $expected (got: $vm_out)"
        [ $bin_ok -eq 0 ] && echo "  BIN missing: $expected (got: $bin_out)"
        FAIL=$((FAIL + 1))
    fi
}

# Test helper: expect compilation to fail
run_error_test() {
    local name="$1"
    local code="$2"

    tmpfile=$(mktemp /tmp/ytest_XXXXXX.y)
    binfile=$(mktemp /tmp/ytest_bin_XXXXXX)
    echo "$code" > "$tmpfile"

    # VM should fail
    vm_out=$(timeout $VM_TO $YBOOT -q "$tmpfile" 2>&1)
    vm_exit=$?

    # Compiled should fail
    $YBOOT --compile "$tmpfile" -o "$binfile" >/dev/null 2>&1
    bin_exit=$?

    rm -f "$tmpfile" "$binfile"

    if [ $vm_exit -ne 0 ] && [ $bin_exit -ne 0 ]; then
        echo -e "${GREEN}PASS${NC} $name (expected error)"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} $name (should have errored)"
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
run_test "typeof: null" 'print(typeof(null));' 'null'
run_test "typeof: array" 'print(typeof([1,2]));' '[long]'
run_test "typeof: map" 'print(typeof({a:1}));' '{a: long}'

# ── Builtins: tostring ──
echo ""
echo "── Builtins: tostring ──"
run_test "tostring: long" 'print(tostring(42));' '42'
run_test "tostring: float" 'print(tostring(3.14));' '3.140000'
run_test "tostring: bool" 'print(tostring(true));' 'true'
run_test "tostring: null" 'print(tostring(null));' 'null'
run_test "tostring: array" 'print(tostring([1,2]));' '[1, 2]'
run_test "tostring: map" 'print(tostring({a:1}));' '{a: 1}'

# ── Builtins: tonum ──
echo ""
echo "── Builtins: tonum ──"
run_test "tonum: integer string" 'print(tonum("123"));' '123'
run_test "tonum: float string" 'print(tonum("3.14"));' '3'
run_test "tonum: negative" 'print(tonum("-42"));' '-42'

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

# ── Builtins: substr ──
echo ""
echo "── Builtins: substr ──"
run_test "substr: middle" 'print(substr("hello", 1, 3));' 'ell'
run_test "substr: from start" 'print(substr("hello", 0, 2));' 'he'
run_test "substr: to end" 'print(substr("hello", 3, 5));' 'lo'
run_test "substr: empty" 'print(substr("hello", 2, 2));' ''

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

# ── Builtins: push ──
echo ""
echo "── Builtins: push ──"
run_test "push: to array" 'let a = [1,2]; print(push(a, 3));' '[1, 2, 3]'
run_test "push: to empty" 'let a = []; print(push(a, 42));' '[42]'

# ── Builtins: map_get/map_set ──
echo ""
echo "── Builtins: map_get/map_set ──"
run_test "map_get: existing" 'let m = {a: 1}; print(map_get(m, "a"));' '1'
run_test "map_get: missing" 'let m = {a: 1}; print(map_get(m, "b"));' 'null'
# NOTE: map_set mutation is a known VM limitation (VM passes clones to builtins)
# and has a double-free in the compiled runtime. Skipping mutation tests.

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
run_test "dot-assign: new key" 'let s = {a: 1}; s.c = 7; print(s.c);' '7'
run_test "dot-assign: string key form" 'let m = {k: "v"}; m["k"] = "w"; print(m.k);' 'w'
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
# Signed division: the VM used to wrap operands through unsigned (to dodge
# signed-overflow UB in + - *), which silently turned / and % into UNSIGNED
# division -- 7 / -2 gave 0 and -7 / 2 gave 9223372036854775804.
run_test "divide: negative divisor" 'print(7 / -2);' '-3'
run_test "divide: negative dividend" 'print(-7 / 2);' '-3'
run_test "divide: both negative" 'print(-7 / -2);' '3'
run_test "modulo: negative divisor" 'print(7 % -2);' '1'
run_test "modulo: negative dividend" 'print(-7 % 2);' '-1'
# LONG_MIN / -1 overflows: idiv raises #DE, so all three engines wrap to
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
# Lexicographic string ordering (all three engines; strcmp semantics).
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
run_test "byte: annotated array literal" 'let b: [byte] = [1, 2, 3]; print(tostring(b));' '[1, 2, 3]'
run_test "byte: widens to long" 'let b: [byte] = [41]; let n = b[0] + 1; print(n);' '42'
run_test "byte: unsigned above 127" 'let b: [byte] = [200]; print(b[0]);' '200'
run_test "byte: push and index" 'let b: [byte] = []; b = push(b, 65); b = push(b, 66); print(from_bytes(b));' 'AB'
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
run_test "double negative" 'print(--5);' '5'

# ── Operators: cons ──
echo ""
echo "── Operators: cons ──"
run_test "cons: to array" 'print(0 :: [1,2,3]);' '[0, 1, 2, 3]'
run_test "cons: to empty" 'print(42 :: []);' '[42]'
run_test "cons: chained" 'print(1 :: 2 :: [3]);' '[1, 2, 3]'

# ── Operators: slice ──
echo ""
echo "── Operators: slice ──"
# NOTE: C parser can't handle postfix on array literals ([1,2,3][0:2] fails)
# Using variables as workaround
run_test "slice: full" 'let a = [1,2,3,4]; print(a[0:4]);' '[1, 2, 3, 4]'
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
run_test "return: bare return is null" 'def f() -> long { return; 999 }; print(f());' 'null'
run_test "return: nested in inner function" 'def outer() -> long { def inner(n: long) -> long { if (n > 0) { return 7; }; 0 }; inner(1) + 1 }; print(outer());' '8'

# ── Functions: closures ──
echo ""
echo "── Functions: closures ──"
run_test "closure: capture" 'def outer() { let x = 10; def inner() { x + 5 }; inner() }; print(outer());' '15'
run_test "closure: counter" 'def make_counter() { let n = 0; def inc() { n = n + 1; n }; inc }; let c = make_counter(); c(); c(); print(c());' '3'

# ── Functions: higher-order ──
echo ""
echo "── Functions: higher-order ──"
run_test "HOF: map" 'def map(f, xs) { let r = []; foreach (x in xs) { r = push(r, f(x)) }; r }; def double(x) { x * 2 }; print(map(double, [1,2,3]));' '[2, 4, 6]'
run_test "HOF: filter" 'def filter(p, xs) { let r = []; foreach (x in xs) { if (p(x)) { r = push(r, x) } }; r }; def is_even(x) { x % 2 == 0 }; print(filter(is_even, [1,2,3,4,5]));' '[2, 4]'
run_test "HOF: reduce" 'def reduce(f, acc, xs) { foreach (x in xs) { acc = f(acc, x) }; acc }; def add(a, b) { a + b }; print(reduce(add, 0, [1,2,3,4,5]));' '15'

# ── Functions: anonymous ──
echo ""
echo "── Functions: anonymous ──"
run_test "anonymous: immediate" 'print((def(x) { x * 2 })(5));' '10'
run_test "anonymous: as arg" 'def apply(f, x) { f(x) }; print(apply(def(n) { n + 1 }, 10));' '11'

# ── Data types: arrays ──
echo ""
echo "── Data types: arrays ──"
run_test "array: literal" 'print([1, 2, 3]);' '[1, 2, 3]'
run_test "array: empty" 'print([]);' '[]'
run_test "array: index" 'let a = [10, 20, 30]; print(a[1]);' '20'
run_test "array: nested" 'let a = [[1,2], [3,4]]; print(a[1][0]);' '3'
run_test "array: mixed types" 'print([1, "two", true, null]);' '[1, two, true, null]'

# ── Data types: maps ──
echo ""
echo "── Data types: maps ──"
run_test "map: literal" 'print({a: 1, b: 2});' '{a: 1, b: 2}'
run_test "map: empty" 'print({});' '{}'
run_test "map: dot access" 'let m = {x: 42}; print(m.x);' '42'
run_test "map: nested" 'let m = {a: {b: 1}}; print(m.a.b);' '1'
run_test "map: function value" 'let m = {f: def(x) { x * 2 }}; print(m.f(5));' '10'

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
run_test "empty program" '' ''
run_test "trailing comma: array" 'print([1, 2, 3,]);' '[1, 2, 3]'
run_test "trailing comma: map" 'print({a: 1, b: 2,});' '{a: 1, b: 2}'
run_test "nested structures" 'let data = {arr: [1, 2], val: 3}; let a = data.arr; print(a[1] + data.val);' '5'
run_test "deep nesting" 'let a = [[[[42]]]]; print(a[0][0][0][0]);' '42'

# ── Error cases ──
# Note: compiler detects errors but exits 0 (known limitation); VM and compiled
# use slightly different error message wording, so match on a common substring.
# KNOWN BUG: unclosed paren/bracket are silently accepted (parser drops the
# malformed expr instead of erroring) — tracked, not asserted here.
echo ""
echo "── Error cases ──"
run_test "undefined variable" 'print(undefined_var);' 'undefined_var'
run_test "type error: call non-function" 'let x = 42; x();' 'non-function'
# Arity is enforced at run time in BOTH engines: the typechecker is advisory,
# so without the generated check a short call read args[] past the end and the
# compiled binary segfaulted (test/y/native/e05_badcall.y).
run_test "arity: too few args" 'def add(a: long, b: long) -> long { a + b }; print(add(1));' 'Argument count mismatch'
run_test "arity: too many args" 'def one(a: long) -> long { a }; print(one(1, 2));' 'Argument count mismatch'
run_test "arity: args to a no-arg function" 'def z() -> long { 7 }; print(z(1));' 'Argument count mismatch'

# ── Self-hosted compiler ──
# Lives in test/sh/test_ycc.sh now (needs ./ycc); run via
# `make test` or `./test/sh/test_ycc.sh`. Skipped here to avoid running it twice. to avoid running it twice.
echo ""
echo "── Self-hosted compiler ──"
echo "  (see tests/test_ycc.sh)"

# ── Summary ──
echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} / $TOTAL total"
echo "═══════════════════════════════════════════"

[ $FAIL -eq 0 ] && exit 0 || exit 1
