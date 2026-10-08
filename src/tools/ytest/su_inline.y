// su_inline.y -- the snippet suites: loops and comprehensive.
//
// Each program runs through BOTH copies -- compiled by the reference and run,
// and compiled by the C copy and run -- and the expected text must appear in
// each side's output, checked separately so one engine regressing alone still
// fails. A compile failure is that side's output, so the same check covers the
// error-message cases. The whole-file loop cases must print the same bytes and
// exit the same way, 0 or 1.
import fs;
import yt;
import yc;

// The C copy's side: compile, run; a failed compile answers its diagnostics.
def copy_run(file: str) -> yt.Res {
    let b = yt.tmp("bin");
    let r = yc.compile(yc.CYCC, [], file, b, 60);
    if (r.code != 0) {
        return { code: 1, out: r.out, err: "", timed_out: false, ms: 0 };
    };
    let o = yc.run_bin(b, [], "", 10);
    fs.remove_file(b);
    o
};

def snippet(name: str, code: str, want: str) {
    let f = yt.tmp("src") + ".y";
    yt.write(f, code);
    let r = yc.ref_run(f, "", 10 * yt.SCALE);
    let c = copy_run(f);
    fs.remove_file(f);
    let rok = r.out.contains(want);
    let cok = c.out.contains(want);
    if (rok && cok) {
        yt.pass(name);
    } else {
        yt.fail(name, "");
        if (!rok) { yt.say("  REF missing: " + want + " (got: " + r.out + ")"); };
        if (!cok) { yt.say("  CPY missing: " + want + " (got: " + c.out + ")"); };
    };
};

def silent(name: str, code: str) {
    let f = yt.tmp("src") + ".y";
    yt.write(f, code);
    let r = yc.ref_run(f, "", 10 * yt.SCALE);
    let c = copy_run(f);
    fs.remove_file(f);
    yt.check(name, r.code == 0 && c.code == 0 && r.out == "" && c.out == "",
        "REF(ec=" + tostring(r.code) + "): '" + r.out + "' / CPY(ec=" + tostring(c.code) + "): '" + c.out + "'");
};

def whole(name: str, file: str) {
    let r = yc.ref_run(file, "", 10 * yt.SCALE);
    let b = yt.tmp("bin");
    let cc = yc.compile(yc.CYCC, [], file, b, 60);
    if (cc.code != 0) {
        yt.fail(name + " (compilation failed)", yt.clip(cc.out, 300));
        return;
    };
    let c = yc.run_bin(b, [], "", 10);
    fs.remove_file(b);
    if (r.code != 0 && r.code != 1) {
        yt.fail(name + " (reference side crashed/hung, exit=" + tostring(r.code) + ")", "");
    } else if (c.code != 0 && c.code != 1) {
        yt.fail(name + " (binary crashed/hung, exit=" + tostring(c.code) + ")", "");
    } else {
        yt.check(name, r.out == c.out && r.code == c.code, "REF(ec=" + tostring(r.code) + "): " + yt.clip(r.out, 200)
            + " / CPY(ec=" + tostring(c.code) + "): " + yt.clip(c.out, 200));
    };
};

// The loop-suite programs run whole: both copies print the same and exit 0 or 1.
let LOOP_FILES = [
    "test_while.y",
    "test_for.y",
    "test_foreach.y",
    "test_forrange.y",
    "helloworld.y",
    "pi.y",
    "array.y",
    "leftfold.y",
];

// [name, program, text the output must hold]: the loop cases, then the
// precedence regressions the audit turned up.
let LOOPS = [
    // Regression: existing examples
    ["while: basic counter", "let i = 0; while (i < 5) { i = i + 1; }; print(i);\n", "5"],
    ["while: accumulator", "let s = 0; let i = 1; while (i <= 100) { s = s + i; i = i + 1; }; print(s);\n", "5050"],
    ["while: zero iterations", "let x = 42; while (false) { x = 0; }; print(x);\n", "42"],
    ["while: nested", "let total = 0; let i = 0; while (i < 3) { let j = 0; while (j < 3) { total = total + 1; j = j + 1; }; i = i + 1; }; print(total);\n", "9"],
    ["for: basic", "let s = 0; for (let i = 0; i < 5; i = i + 1) { s = s + i; }; print(s);\n", "10"],
    ["for: countdown", "let s = \"\"; for (let i = 5; i > 0; i = i - 1) { s = s + tostring(i); }; print(s);\n", "54321"],
    ["for: step by 3", "let c = 0; for (let i = 0; i < 10; i = i + 3) { c = c + 1; }; print(c);\n", "4"],
    ["for: no init", "let i = 3; let s = 0; for (; i > 0; i = i - 1) { s = s + i; }; print(s);\n", "6"],
    ["for: zero iterations", "let x = 99; for (let i = 10; i < 5; i = i + 1) { x = 0; }; print(x);\n", "99"],
    ["for: nested", "let s = 0; for (let i = 0; i < 4; i = i + 1) { for (let j = 0; j < 4; j = j + 1) { s = s + 1; }; }; print(s);\n", "16"],
    ["foreach: sum array", "let s = 0; foreach (x in [10, 20, 30]) { s = s + x; }; print(s);\n", "60"],
    ["foreach: string concat", "let r = \"\"; foreach (w in [\"a\", \"b\", \"c\"]) { r = r + w; }; print(r);\n", "abc"],
    ["foreach: empty array", "let x = 42; foreach (i in []) { x = 0; }; print(x);\n", "42"],
    ["foreach: over range()", "let s = 0; foreach (i in range(5)) { s = s + i; }; print(s);\n", "10"],
    ["foreach: nested", "let s = 0; foreach (a in [1, 2]) { foreach (b in [10, 20]) { s = s + a * b; }; }; print(s);\n", "90"],
    ["foreach: single element", "let s = 0; foreach (x in [7]) { s = x; }; print(s);\n", "7"],
    ["range: 0..5", "let s = 0; for i in 0..5 { s = s + i; }; print(s);\n", "10"],
    ["range: 3..7", "let s = 0; for i in 3..7 { s = s + i; }; print(s);\n", "18"],
    ["range: empty (start==end)", "let x = 42; for i in 5..5 { x = 0; }; print(x);\n", "42"],
    ["range: empty (start>end)", "let x = 42; for i in 10..3 { x = 0; }; print(x);\n", "42"],
    ["range: nested", "let s = 0; for i in 0..3 { for j in 0..3 { s = s + i + j; }; }; print(s);\n", "18"],
    ["range: expression bounds", "let n = 3; let s = 0; for i in 0..n*2 { s = s + 1; }; print(s);\n", "6"],
    ["range: variable used after loop", "let last = 0; for i in 0..10 { last = i; }; print(last);\n", "9"],
    ["loop in function", "def sum_to(n: long) -> long { let s = 0; for i in 0..n+1 { s = s + i; }; s }; print(sum_to(10));\n", "55"],
    ["function with while", "def fib(n: long) -> long { let a = 0; let b = 1; let i = 0; while (i < n) { let t = a + b; a = b; b = t; i = i + 1; }; a }; print(fib(10));\n", "55"],
    ["foreach with function call", "def double(x: long) -> long { x * 2 }; let s = 0; foreach (v in [1, 2, 3]) { s = s + double(v); }; print(s);\n", "12"],
    ["loop building array result", "let s = 0; for i in 1..6 { s = s + i * i; }; print(s);\n", "55"],
    ["precedence: mul before add", "print(2 * 3 + 4);\n", "10"],
    ["precedence: left-assoc subtraction", "print(10 - 2 - 3);\n", "5"],
    ["precedence: left-assoc division", "print(100 / 10 / 2);\n", "5"],
    ["precedence: mixed", "print(2 + 3 * 4 - 1);\n", "13"],
    ["precedence: comparison lower than arithmetic", "print(2 + 3 > 4);\n", "true"],
    ["precedence: parens override", "print((2 + 3) * 4);\n", "20"],
    ["negative float", "print(-3.14);\n", "-3.14"],
    ["negative float: -0.5", "print(-0.5);\n", "-0.5"],
    ["else if chain", "let x = 2; if (x == 1) { print(\"one\"); } else if (x == 2) { print(\"two\"); } else { print(\"other\"); };\n", "two"],
    ["else if: falls to else", "let x = 9; if (x == 1) { print(\"one\"); } else if (x == 2) { print(\"two\"); } else { print(\"other\"); };\n", "other"],
    ["if without else", "if (true) { print(\"yes\"); };\n", "yes"],
    ["cons operator", "print(0 :: [1, 2, 3]);\n", "[0, 1, 2, 3]"],
    ["empty array slice", "let a: [long] = []; print(a[0:1]);\n", "[]"],
    ["modulo precedence", "print(10 % 3 + 1);\n", "2"],
];

// [name, program, text the output must hold], by feature group. A compile
// failure is the copy's output, so the error-message cases use the same check.
let COMP = [
    // Builtins: typeof
    ["typeof: long", "print(typeof(42));\n", "long"],
    ["typeof: float", "print(typeof(3.14));\n", "float"],
    ["typeof: str", "print(typeof(\"hi\"));\n", "str"],
    ["typeof: bool", "print(typeof(true));\n", "bool"],
    ["typeof: none", "print(typeof(none));\n", "none"],
    ["typeof: option", "let o: long? = some(1); print(typeof(o));\n", "long?"],
    ["typeof: array", "print(typeof([1,2]));\n", "[long]"],
    // The spelling is the one a diagnostic gives the same type (m16): types.y has
    // one renderer, so `typeof` and "expected { a: long }" cannot drift apart.
    ["typeof: record", "print(typeof({a:1}));\n", "{ a: long }"],
    ["typeof: function", "def f(x: long) -> long { x }; print(typeof(f));\n", "(long) -> long"],
    ["typeof: nested function", "def g(f: (long) -> long) -> long { f(1) }; print(typeof(g));\n", "((long) -> long) -> long"],
    ["typeof: fixed array", "let a: [long; 2] = [1,2]; print(typeof(a));\n", "[long; 2]"],
    ["typeof: mutex", "let m = mutex(); print(typeof(m));\n", "mutex"],
    // Builtins: tostring
    ["tostring: long", "print(tostring(42));\n", "42"],
    ["tostring: float", "print(tostring(3.14));\n", "3.140000"],
    ["tostring: bool", "print(tostring(true));\n", "true"],
    ["tostring: none", "print(tostring(none));\n", "none"],
    ["tostring: array", "print(tostring([1,2]));\n", "[1, 2]"],
    ["tostring: map", "print(tostring({a:1}));\n", "{a: 1}"],
    // Builtins: tolong
    ["tolong: integer string", "print(tolong(\"123\"));\n", "123"],
    ["tolong: float string is not a whole number", "print(tolong(\"3.14\"));\n", "none"],
    ["tolong: negative", "print(tolong(\"-42\"));\n", "-42"],
    // print separates its arguments with a space only when they are strings, so
    // two longs come out as "2-2": the point here is that -2.75 gives -2 and not
    // -3, which is what separates truncation from floor.
    ["tolong: float truncates toward zero", "print(tolong(2.75), tolong(-2.75));\n", "2-2"],
    ["tolong: method form", "print(\"17\".tolong());\n", "17"],
    // Builtins: tofloat
    ["tofloat: fraction", "print(tofloat(\"3.14\"));\n", "3.140000"],
    ["tofloat: negative", "print(tofloat(\"-0.5\"));\n", "-0.500000"],
    ["tofloat: long widens", "print(tofloat(7));\n", "7.000000"],
    ["tofloat: method form", "print(\"2.5\".tofloat());\n", "2.500000"],
    // An exponent is not read: the scan stops at the 'e', the same way tolong
    // stops at the '.' -- one tolerance for both, so a value cannot behave
    // differently depending on which conversion it went through.
    ["tofloat: no exponent is not read", "print(tofloat(\"1e9\"));\n", "none"],
    // Builtins: len
    ["len: string", "print(len(\"hello\"));\n", "5"],
    ["len: array", "print(len([1,2,3]));\n", "3"],
    ["len: empty array", "print(len([]));\n", "0"],
    ["len: empty string", "print(len(\"\"));\n", "0"],
    // Builtins: ord/chr
    ["ord: A", "print(ord(\"A\"));\n", "65"],
    ["ord: a", "print(ord(\"a\"));\n", "97"],
    ["chr: 65", "print(chr(65));\n", "A"],
    ["chr: 97", "print(chr(97));\n", "a"],
    // String slicing
    ["slice: middle", "print(\"hello\"[1:4]);\n", "ell"],
    ["slice: from start", "print(\"hello\"[:2]);\n", "he"],
    ["slice: to end", "print(\"hello\"[3:]);\n", "lo"],
    ["slice: empty", "print(\"hello\"[2:2]);\n", ""],
    // Builtins: split/join
    ["split: comma", "print(split(\"a,b,c\", \",\"));\n", "[a, b, c]"],
    ["split: space", "print(split(\"x y z\", \" \"));\n", "[x, y, z]"],
    ["join: dash", "print(join([\"x\",\"y\",\"z\"], \"-\"));\n", "x-y-z"],
    ["join: empty sep", "print(join([\"a\",\"b\",\"c\"], \"\"));\n", "abc"],
    // Builtins: trim
    ["trim: spaces", "print(trim(\"  hi  \"));\n", "hi"],
    ["trim: tabs", "print(trim(\"\\t\\thello\\t\\t\"));\n", "hello"],
    ["trim: no whitespace", "print(trim(\"clean\"));\n", "clean"],
    // Builtins: index_of/last_index_of
    ["index_of: found", "print(index_of(\"hello\", \"ll\"));\n", "2"],
    ["index_of: not found", "print(index_of(\"hello\", \"xyz\"));\n", "-1"],
    ["last_index_of: found", "print(last_index_of(\"hello\", \"l\"));\n", "3"],
    ["last_index_of: not found", "print(last_index_of(\"hello\", \"xyz\"));\n", "-1"],
    // Removed builtins
    ["push is gone", "let a = [1,2]; print(push(a, 3));\n", "undefined function 'push'"],
    ["prepend is gone", "let a = [1,2]; print(prepend(0, a));\n", "undefined function 'prepend'"],
    // Builtins: map_get/map_set
    // Maps (dynamic) are a separate type from records (static structs):
    // {K: V} with a hashable key type K and one homogeneous value type V.
    // Quoted keys make a map literal; record keys are identifiers. Keying is
    // symbolic: a.key for records, a['key'] for maps. (map_get/map_set/push
    // are gone -- symbol ops replace them.)
    ["map: get existing", "let m = {\"a\": 1}; print(m[\"a\"]);\n", "1"],
    ["map: get missing", "let m = {\"a\": 1}; print(m[\"b\"]);\n", "none"],
    ["map: set overwrite", "let m = {\"a\": 1}; m[\"a\"] = 2; print(m[\"a\"]);\n", "2"],
    ["map: set new key", "let m = {\"a\": 1}; m[\"b\"] = 3; print(m[\"b\"]);\n", "3"],
    ["map: homogeneous values", "let m = {\"a\": 1, \"b\": 2}; print(m[\"b\"]);\n", "2"],
    ["map_get is gone", "let m = {\"a\": 1}; print(map_get(m, \"a\"));\n", "undefined function 'map_get'"],
    ["map_set is gone", "let m = {\"a\": 1}; map_set(m, \"a\", 2);\n", "undefined function 'map_set'"],
    // Records: spread
    ["spread: after explicit keys", "let b = {x: 1, y: 2}; print({a: 0, ...b});\n", "{a: 0, x: 1, y: 2}"],
    ["spread: two sources, later wins", "let b = {x: 1, y: 2}; let c = {y: 9, z: 3}; print({...b, ...c});\n", "{x: 1, y: 9, z: 3}"],
    ["spread: explicit key after spread wins", "let b = {x: 1, y: 2}; print({...b, y: 100});\n", "{x: 1, y: 100}"],
    ["spread: copy", "let b = {x: 1, y: 2}; print({...b});\n", "{x: 1, y: 2}"],
    ["spread: source untouched", "let b = {x: 1}; let d = {...b, w: 4}; print(b);\n", "{x: 1}"],
    ["spread: field read from result", "let b = {x: 1}; let d = {...b, w: 4}; print(d.w);\n", "4"],
    // Records: field assignment
    ["dot-assign: overwrite", "let s = {a: 1, b: 2}; s.a = 9; print(s.a);\n", "9"],
    ["dot-assign: leaves others", "let s = {a: 1, b: 2}; s.a = 9; print(s.b);\n", "2"],
    // A record's shape is fixed at compile time (struct layout): writing a
    // field the shape does not have is a compile error.
    ["dot-assign: new key is rejected", "let s = {a: 1}; s.c = 7; print(s.c);\n", "record has no field 'c'"],
    ["dot-assign: string key form is map-only", "let r = {k: \"v\"}; r[\"k\"] = \"w\"; print(r.k);\n", "cannot index { k: str } (only arrays and maps)"],
    ["index-assign: map string key", "let m = {\"k\": \"v\"}; m[\"k\"] = \"w\"; print(m[\"k\"]!);\n", "w"],
    ["dot-assign: visible through an alias", "let n = {inner: {n: 1}}; let t = n.inner; t.n = 5; print(n.inner.n);\n", "5"],
    ["index-assign still works", "let a = [1,2,3]; a[1] = 20; print(a);\n", "[1, 20, 3]"],
    // Postfix: field access
    ["dot then index", "let m = { xs: [10, 20, 30] }; print(m.xs[1]);\n", "20"],
    ["dot then index in arithmetic", "let m = { xs: [10, 20, 30] }; print(m.xs[0] + m.xs[2]);\n", "40"],
    ["not of a field", "let m = { flag: false }; print(!m.flag);\n", "true"],
    ["negate a field", "let m = { n: 5 }; print(-m.n);\n", "-5"],
    ["index then dot", "let arr = [{v: 7}, {v: 8}]; print(arr[1].v);\n", "8"],
    ["nested fields", "let n = { inner: { deep: 5 } }; print(n.inner.deep);\n", "5"],
    ["field of a string", "let m = { name: \"hi\" }; print(m.name);\n", "hi"],
    // Operators: short-circuit logic
    ["and: truth table TT", "print(true && true);\n", "true"],
    ["and: truth table TF", "print(true && false);\n", "false"],
    ["or: truth table FT", "print(false || true);\n", "true"],
    ["or: truth table FF", "print(false || false);\n", "false"],
    ["and: right side not evaluated", "def boom() -> bool { print(999); true }; if (false && boom()) { print(\"bad\"); } else { print(\"ok\"); };\n", "ok"],
    ["or: right side not evaluated", "def boom() -> bool { print(999); true }; if (true || boom()) { print(\"ok\"); };\n", "ok"],
    ["and: guards an out-of-range index", "let a = [1,2]; let i = 5; if (i < len(a) && a[i] == 1) { print(\"bad\"); } else { print(\"guarded\"); };\n", "guarded"],
    ["or: guards an out-of-range index", "let a = [1,2]; let i = 5; if (i >= len(a) || a[i] == 1) { print(\"guarded\"); };\n", "guarded"],
    // Operators: array concat and compound assignment
    ["array + array", "let a = [1,2]; let b = [3,4]; print(a + b);\n", "[1, 2, 3, 4]"],
    ["array + element", "let a = [1,2]; print(a + 9);\n", "[1, 2, 9]"],
    ["element + array", "let a = [1,2]; print(0 + a);\n", "[0, 1, 2]"],
    ["array literals on both sides", "print([1,2] + [3]);\n", "[1, 2, 3]"],
    ["array + leaves operands alone", "let a = [1,2]; let b = a + 3; print(a);\n", "[1, 2]"],
    ["array + with strings stays an array", "let s = [\"x\"]; print(s + \"y\");\n", "[x, y]"],
    ["empty array + element", "print([] + 1);\n", "[1]"],
    ["array + empty array", "let a = [1]; print(a + []);\n", "[1]"],
    ["compound: array append", "let a = [1,2]; a += 3; print(a);\n", "[1, 2, 3]"],
    ["compound: array concat", "let a = [1]; a += [2,3]; print(a);\n", "[1, 2, 3]"],
    ["compound: numeric add", "let n = 10; n += 5; print(n);\n", "15"],
    ["compound: numeric sub", "let n = 10; n -= 3; print(n);\n", "7"],
    ["compound: numeric mul", "let n = 10; n *= 3; print(n);\n", "30"],
    ["compound: numeric div", "let n = 12; n /= 4; print(n);\n", "3"],
    ["compound: string append", "let s = \"ab\"; s += \"cd\"; print(s);\n", "abcd"],
    ["compound: in a loop", "let i = 0; while (i < 3) { i += 1; }; print(i);\n", "3"],
    // Operators: arithmetic
    ["add", "print(2 + 3);\n", "5"],
    ["subtract", "print(10 - 4);\n", "6"],
    ["multiply", "print(3 * 4);\n", "12"],
    ["divide", "print(20 / 4);\n", "5"],
    ["modulo", "print(10 % 3);\n", "1"],
    ["precedence: mul before add", "print(2 + 3 * 4);\n", "14"],
    ["precedence: parens", "print((2 + 3) * 4);\n", "20"],
    ["precedence: left-assoc div", "print(100 / 10 / 2);\n", "5"],
    ["precedence: left-assoc sub", "print(10 - 2 - 3);\n", "5"],
    // Signed division: operands are NOT wrapped through unsigned (an older
    // engine did that to dodge signed-overflow UB in + - *, which silently turned
    // / and % into UNSIGNED division -- 7 / -2 gave 0 and -7 / 2 gave
    // 9223372036854775804). These cases pin the current, signed result.
    ["divide: negative divisor", "print(7 / -2);\n", "-3"],
    ["divide: negative dividend", "print(-7 / 2);\n", "-3"],
    ["divide: both negative", "print(-7 / -2);\n", "3"],
    ["modulo: negative divisor", "print(7 % -2);\n", "1"],
    ["modulo: negative dividend", "print(-7 % 2);\n", "-1"],
    // LONG_MIN / -1 overflows: idiv raises #DE, so both compilers wrap to
    // LONG_MIN (and LONG_MIN % -1 is 0) instead of trapping.
    ["divide: LONG_MIN by -1", "let mn = -9223372036854775807 - 1; print(mn / -1);\n", "-9223372036854775808"],
    ["modulo: LONG_MIN by -1", "let mn = -9223372036854775807 - 1; print(mn % -1);\n", "0"],
    // Operators: comparison
    ["less than: true", "print(1 < 2);\n", "true"],
    ["less than: false", "print(2 < 1);\n", "false"],
    ["greater than: true", "print(3 > 2);\n", "true"],
    ["greater than: false", "print(2 > 3);\n", "false"],
    ["less or equal: true", "print(2 <= 2);\n", "true"],
    ["greater or equal: true", "print(3 >= 3);\n", "true"],
    // Lexicographic string ordering (both compilers; strcmp semantics).
    ["str less than: true", "print(\"a\" < \"b\");\n", "true"],
    ["str less than: false", "print(\"b\" < \"a\");\n", "false"],
    ["str prefix is smaller", "print(\"ab\" < \"abc\");\n", "true"],
    ["str empty is smallest", "print(\"\" < \"a\");\n", "true"],
    ["str case: upper before lower", "print(\"Z\" < \"a\");\n", "true"],
    ["str greater or equal", "print(\"apple\" >= \"apple\");\n", "true"],
    // byte type and byte/string conversion
    ["bytes: length", "print(len(bytes(\"Hello\")));\n", "5"],
    ["bytes: first element", "let b = bytes(\"Hello\"); print(b[0]);\n", "72"],
    ["bytes: round trip", "print(from_bytes(bytes(\"round trip\")));\n", "round trip"],
    ["bytes: empty string", "print(len(bytes(\"\")));\n", "0"],
    ["from_bytes: literal", "let b: [byte] = [104, 105]; print(from_bytes(b));\n", "hi"],
    ["byte: annotated array literal", "let b: [byte] = [1, 2, 3]; print(tostring(b));\n", "b'\\x01\\x02\\x03'"],
    ["byte: widens to long", "let b: [byte] = [41]; let n = b[0] + 1; print(n);\n", "42"],
    ["byte: unsigned above 127", "let b: [byte] = [200]; print(b[0]);\n", "200"],
    ["byte: push and index", "let b: [byte] = []; b += 65; b += 66; print(from_bytes(b));\n", "AB"],
    ["byte: slice", "let b: [byte] = [97, 98, 99, 100]; print(from_bytes(b[1:3]));\n", "bc"],
    ["tostring: array of long", "print(tostring([1, 2, 3]));\n", "[1, 2, 3]"],
    ["tostring: array of str", "print(tostring([\"a\", \"b\"]));\n", "[a, b]"],
    ["tostring: nested array", "print(tostring([[1, 2], [3]]));\n", "[[1, 2], [3]]"],
    ["equal: true", "print(5 == 5);\n", "true"],
    ["equal: false", "print(5 == 6);\n", "false"],
    ["not equal: true", "print(5 != 6);\n", "true"],
    ["not equal: false", "print(5 != 5);\n", "false"],
    // Operators: logical
    ["and: true", "print(true && true);\n", "true"],
    ["and: false", "print(true && false);\n", "false"],
    ["or: true", "print(false || true);\n", "true"],
    ["or: false", "print(false || false);\n", "false"],
    ["not: true", "print(!false);\n", "true"],
    ["not: false", "print(!true);\n", "false"],
    ["complex logical", "print(1 < 2 && 3 > 2 || false);\n", "true"],
    // Operators: unary
    ["unary minus", "print(-5);\n", "-5"],
    ["unary minus expr", "print(-(2 + 3));\n", "-5"],
    ["double negative", "print(-(-5));\n", "5"],
    ["prefix -- is decrement", "let x = 5; --x; print(x);\n", "4"],
    // Operators: cons
    ["cons: to array", "print(0 :: [1,2,3]);\n", "[0, 1, 2, 3]"],
    ["cons: to empty", "print(42 :: []);\n", "[42]"],
    ["cons: chained", "print(1 :: 2 :: [3]);\n", "[1, 2, 3]"],
    // Operators: slice
    // A postfix chain straight off an array literal parses fine: the parser runs
    // parse_primary (which builds the literal) and then its own postfix loop, so
    // [1,2,3][0:2] slices the literal itself — no binding needed.
    ["slice: full", "let a = [1,2,3,4]; print(a[0:4]);\n", "[1, 2, 3, 4]"],
    ["slice: literal operand", "print([1,2,3][0:2]);\n", "[1, 2]"],
    ["index: literal operand", "print([1,2,3][1]);\n", "2"],
    ["slice: partial", "let a = [1,2,3,4]; print(a[1:3]);\n", "[2, 3]"],
    ["slice: from start", "let a = [1,2,3,4]; print(a[:2]);\n", "[1, 2]"],
    ["slice: to end", "let a = [1,2,3,4]; print(a[2:]);\n", "[3, 4]"],
    ["slice: all", "let a = [1,2,3,4]; print(a[:]);\n", "[1, 2, 3, 4]"],
    ["slice: empty result", "let a = [1,2,3]; print(a[2:1]);\n", "[]"],
    // Literals: numeric formats
    ["hex literal", "print(0xff);\n", "255"],
    ["hex literal: uppercase", "print(0xFFAB);\n", "65451"],
    ["hex literal: mixed case prefix", "print(0XFF);\n", "255"],
    ["binary literal", "print(0b101);\n", "5"],
    ["binary literal: uppercase prefix", "print(0B1111);\n", "15"],
    ["radix: arithmetic", "print(0x10 + 0b10);\n", "18"],
    ["radix: underscores", "print(0xdead_beef);\n", "3735928559"],
    ["radix: negative", "print(-0x10);\n", "-16"],
    ["exponent: integer mantissa", "print(1e3);\n", "1000.000000"],
    ["exponent: float mantissa", "print(1.5e2);\n", "150.000000"],
    ["exponent: negative exponent", "print(2.5e-2);\n", "0.025000"],
    ["decimal still works", "print(42);\n", "42"],
    ["float still works", "print(1.25);\n", "1.250000"],
    // Functions: basic
    ["function: simple", "def add(a: long, b: long) -> long { a + b }; print(add(2, 3));\n", "5"],
    ["function: no params", "def answer() -> long { 42 }; print(answer());\n", "42"],
    ["function: string return", "def greet(name: str) -> str { \"Hello \" + name }; print(greet(\"World\"));\n", "Hello World"],
    // Functions: recursion
    ["recursion: factorial", "def fact(n: long) -> long { if (n <= 1) { 1 } else { n * self(n - 1) } }; print(fact(5));\n", "120"],
    ["recursion: fibonacci", "def fib(n: long) -> long { if (n < 2) { n } else { self(n-1) + self(n-2) } }; print(fib(10));\n", "55"],
    ["recursion: countdown", "def count(n: long) -> str { if (n <= 0) { \"done\" } else { tostring(n) + \" \" + self(n-1) } }; print(count(3));\n", "3 2 1 done"],
    ["self: still the recursion handle", "def fact(n: long) -> long { if (n <= 1) { 1 } else { n * self(n - 1) } }; print(fact(5));\n", "120"],
    ["self: usable as a parameter name", "def f(self: long) -> long { self + 1 }; print(f(41));\n", "42"],
    ["self: usable as a local name", "def g() -> long { let self = 5; self * 2 }; print(g());\n", "10"],
    // Functions: early return
    ["return: guard clause", "def f(n: long) -> long { if (n < 0) { return 0 - n; }; n * 2 }; print(f(-5));\n", "5"],
    ["return: falls through", "def f(n: long) -> long { if (n < 0) { return 0 - n; }; n * 2 }; print(f(3));\n", "6"],
    ["return: skips rest of body", "def f() -> long { return 1; 999 }; print(f());\n", "1"],
    ["return: out of a while loop", "def f(xs: [long]) -> long { let i = 0; while (i < len(xs)) { if (xs[i] > 10) { return xs[i]; }; i = i + 1; }; 0 - 1 }; print(f([1, 2, 42, 7]));\n", "42"],
    ["return: loop finishes without returning", "def f(xs: [long]) -> long { let i = 0; while (i < len(xs)) { if (xs[i] > 10) { return xs[i]; }; i = i + 1; }; 0 - 1 }; print(f([1, 2]));\n", "-1"],
    ["return: bare return makes a void def", "def f() { return; }; print(f());\n", "got void"],
    ["return: bare return in a typed def", "def f() -> long { return; }; print(f());\n", "'return': expected long, got void"],
    ["return: -> void discards the tail", "def f(x: long) -> void { print(x); x }; f(4);\n", "4"],
    ["return: value in a void def", "def f() -> void { return 1; };\n", "'return': expected void, got long"],
    ["return: nested in inner function", "def outer() -> long { def inner(n: long) -> long { if (n > 0) { return 7; }; 0 }; inner(1) + 1 }; print(outer());\n", "8"],
    // Void: disagreeing if arms
    // When the arms of an if/else disagree on a type, the whole if is void: a
    // statement, legal on its own, rejected wherever a value is needed.
    ["void-if: legal as a statement", "if (true) { 1 } else { \"a\" }; print(2);\n", "2"],
    ["void-if: agreeing arms keep their type", "let x = if (false) { 1 } else { 2 }; print(x);\n", "2"],
    ["void-if: cannot be bound", "let x = if (true) { 1 } else { \"a\" };\n", "cannot bind a void value to 'x'"],
    ["void-if: cannot be printed", "print(if (true) { 1 } else { \"a\" });\n", "got void"],
    ["void-if: cannot be an argument", "def f(v) { v }; f(if (true) { 1 } else { \"a\" });\n", "'f' arg 0: cannot pass a void value"],
    ["void-if: cannot be returned as a value", "def f() -> long { if (true) { 1 } else { \"a\" } };\n", "'f' body: expected long, got void"],
    // Options: none and postfix !
    ["none: prints as none", "let a: long? = none; print(a);\n", "none"],
    ["none: is-none check", "let a: long? = none; print(a == none);\n", "true"],
    ["none: some is not none", "let a: long? = some(0); print(a == none);\n", "false"],
    ["none: a plain value is not an option", "let a: long? = 5;\n", "expected long?, got long"],
    ["none: str is not optional", "let s = \"x\"; print(s == none);\n", "'==' compares str with none"],
    ["null: is gone", "let x = null;\n", "undefined variable 'null'"],
    ["unwrap-!: some value", "let a: long? = some(41); print(a! + 1);\n", "42"],
    ["unwrap-!: same as unwrap()", "let a: str? = some(\"hi\"); print(a! == unwrap(a));\n", "true"],
    ["unwrap-!: on a map read", "let m = {\"k\": 7}; print(m[\"k\"]! * 6);\n", "42"],
    ["unwrap-!: binds tighter than unary !", "let b: bool? = some(false); print(!b!);\n", "true"],
    ["unwrap-!: none traps", "let a: long? = none; print(a!);\n", "runtime error: unwrap of none"],
    ["unwrap-!: != still lexes", "let a = 1; print(a != 2);\n", "true"],
    ["unwrap-!: needs an option", "let a = 1; print(a!);\n", "unwrap needs an option"],
    // Functions: closures
    ["closure: capture", "def outer() { let x = 10; def inner() { x + 5 }; inner() }; print(outer());\n", "15"],
    ["closure: counter", "def make_counter() { let n = 0; def inc() { n = n + 1; n }; inc }; let c = make_counter(); c(); c(); print(c());\n", "3"],
    // Functions: higher-order
    ["HOF: map", "def map(f: (long) -> long, xs: [long]) -> [long] { let r: [long] = []; foreach (x in xs) { r += f(x) }; r }; def double(x: long) { x * 2 }; print(map(double, [1,2,3]));\n", "[2, 4, 6]"],
    ["HOF: filter", "def filter(p: (long) -> bool, xs: [long]) -> [long] { let r: [long] = []; foreach (x in xs) { if (p(x)) { r += x; 0; } else { 0; }; 0 }; r }; def is_even(x: long) { x % 2 == 0 }; print(filter(is_even, [1,2,3,4,5]));\n", "[2, 4]"],
    ["HOF: reduce", "def reduce(f: (long, long) -> long, acc: long, xs: [long]) -> long { foreach (x in xs) { acc = f(acc, x) }; acc }; def add(a: long, b: long) { a + b }; print(reduce(add, 0, [1,2,3,4,5]));\n", "15"],
    // Functions: anonymous
    ["anonymous: immediate", "print((def(x: long) { x * 2 })(5));\n", "10"],
    ["anonymous: as arg", "def apply(f: (long) -> long, x: long) { f(x) }; print(apply(def(n: long) { n + 1 }, 10));\n", "11"],
    // Data types: arrays
    ["array: literal", "print([1, 2, 3]);\n", "[1, 2, 3]"],
    ["array: empty", "print([]);\n", "[]"],
    ["array: index", "let a = [10, 20, 30]; print(a[1]);\n", "20"],
    ["array: nested", "let a = [[1,2], [3,4]]; print(a[1][0]);\n", "3"],
    ["array: mixed types is rejected", "print([1, \"two\", true, none]);\n", "array element: expected long, got str"],
    // Data types: maps
    ["map: literal", "print({a: 1, b: 2});\n", "{a: 1, b: 2}"],
    ["map: empty", "print({});\n", "{}"],
    ["map: dot access", "let m = {x: 42}; print(m.x);\n", "42"],
    ["map: nested", "let m = {a: {b: 1}}; print(m.a.b);\n", "1"],
    ["map: function value", "let m = {f: def(x: long) { x * 2 }}; print(m.f(5));\n", "10"],
    // Data types: strings
    ["string: concat", "print(\"Hello\" + \" \" + \"World\");\n", "Hello World"],
    ["string: with number", "print(\"Value: \" + tostring(42));\n", "Value: 42"],
    ["string: escapes", "print(\"Line1\\nLine2\");\n", "Line1\nLine2"],
    ["string: tab", "print(\"Col1\\tCol2\");\n", "Col1\tCol2"],
    ["string: hex escape", "print(\"\\x41\\x42\\x43\");\n", "ABC"],
    // Control flow: if/else
    ["if: true branch", "if (true) { print(\"yes\"); };\n", "yes"],
    ["if: false branch", "if (false) { print(\"no\"); } else { print(\"yes\"); };\n", "yes"],
    ["if-else chain", "let x = 2; if (x == 1) { print(\"one\"); } else if (x == 2) { print(\"two\"); } else { print(\"other\"); };\n", "two"],
    ["if: nested", "if (true) { if (false) { print(\"inner\"); } else { print(\"outer\"); } };\n", "outer"],
    // Control flow: while
    ["while: counter", "let i = 0; while (i < 5) { i = i + 1 }; print(i);\n", "5"],
    ["while: accumulator", "let s = 0; let i = 1; while (i <= 10) { s = s + i; i = i + 1 }; print(s);\n", "55"],
    ["while: nested", "let total = 0; let i = 0; while (i < 3) { let j = 0; while (j < 3) { total = total + 1; j = j + 1 }; i = i + 1 }; print(total);\n", "9"],
    // Control flow: for
    ["for: basic", "let s = 0; for (let i = 0; i < 5; i = i + 1) { s = s + i }; print(s);\n", "10"],
    ["for: countdown", "let s = \"\"; for (let i = 5; i > 0; i = i - 1) { s = s + tostring(i) }; print(s);\n", "54321"],
    ["for: nested", "let s = 0; for (let i = 0; i < 3; i = i + 1) { for (let j = 0; j < 3; j = j + 1) { s = s + 1 } }; print(s);\n", "9"],
    // Control flow: foreach
    ["foreach: sum", "let s = 0; foreach (x in [1,2,3,4,5]) { s = s + x }; print(s);\n", "15"],
    ["foreach: string concat", "let r = \"\"; foreach (w in [\"a\", \"b\", \"c\"]) { r = r + w }; print(r);\n", "abc"],
    ["foreach: nested", "let s = 0; foreach (a in [1,2]) { foreach (b in [10,20]) { s = s + a * b } }; print(s);\n", "90"],
    // Control flow: for..in range
    ["range: 0..5", "let s = 0; for i in 0..5 { s = s + i }; print(s);\n", "10"],
    ["range: 3..7", "let s = 0; for i in 3..7 { s = s + i }; print(s);\n", "18"],
    ["range: nested", "let s = 0; for i in 0..3 { for j in 0..3 { s = s + i + j } }; print(s);\n", "18"],
    // Declarations
    ["let: basic", "let x = 42; print(x);\n", "42"],
    ["let: reassign", "let x = 1; x = 2; print(x);\n", "2"],
    ["const: basic", "const x = 42; print(x);\n", "42"],
    ["def: function", "def f() { 99 }; print(f());\n", "99"],
    // Edge cases
    ["trailing comma: array", "print([1, 2, 3,]);\n", "[1, 2, 3]"],
    ["trailing comma: map", "print({a: 1, b: 2,});\n", "{a: 1, b: 2}"],
    ["nested structures", "let data = {arr: [1, 2], val: 3}; let a = data.arr; print(a[1] + data.val);\n", "5"],
    ["deep nesting", "let a = [[[[42]]]]; print(a[0][0][0][0]);\n", "42"],
    // Error cases
    // A type/name error is a STATIC error: the checker rejects the file, the
    // compiler prints "L:C: error: ..." and exits 1 without writing a binary.
    // Both compilers must say it, so these cases match the diagnostic itself.
    ["undefined variable", "print(undefined_var);\n", "undefined_var"],
    ["type error: call non-function", "let x = 42; x();\n", "is not a function"],
    // An unterminated literal list is a syntax error, not a silently dropped
    // expression: the parser plants an "err" node and the checker reports it.
    ["unclosed paren is rejected", "print((1 + 2);\n", "unexpected ';' (expected ',' or ')')"],
    ["unclosed bracket is rejected", "let a = [1, 2; print(a);\n", "unexpected ';' (expected ',' or ']')"],
    // Arity is a STATIC error, reported by the type checker with the call's
    // line:col ("'add' takes 2 args, got 1"); nothing is emitted, nothing runs.
    // (It was a run-time check in the old engines, where a short call read the
    // argument array past its end -- see test/y/native/e05_badcall.y.)
    ["arity: too few args", "def add(a: long, b: long) -> long { a + b }; print(add(1));\n", "takes 2 args, got 1"],
    ["arity: too many args", "def one(a: long) -> long { a }; print(one(1, 2));\n", "takes 1 args, got 2"],
    ["arity: args to a no-arg function", "def z() -> long { 7 }; print(z(1));\n", "takes 0 args, got 1"],
    // Self-hosted compiler
];

// Programs that must print nothing and exit 0.
let SILENT = [
    ["empty program", "\n"],
];

def loops() -> [yt.Case] {
    let cs: [yt.Case] = [];
    foreach (n in LOOP_FILES) {
        let f = yc.ROOT + "/test/y/examples/" + n;
        cs += yt.case_of("loops", n, () => whole(n, f));
    };
    foreach (t in LOOPS) {
        cs += yt.case_of("loops", t[0], () => snippet(t[0], t[1], t[2]));
    };
    cs
};

def comprehensive() -> [yt.Case] {
    let cs: [yt.Case] = [];
    foreach (t in COMP) {
        cs += yt.case_of("comprehensive", t[0], () => snippet(t[0], t[1], t[2]));
    };
    foreach (t in SILENT) {
        cs += yt.case_of("comprehensive", t[0], () => silent(t[0], t[1]));
    };
    cs
};

export { loops, comprehensive, snippet };
