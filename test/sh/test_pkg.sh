#!/bin/bash
# test/sh/test_pkg.sh — packages: `ycc build` and `ycc vendor` (pkg.y; ycc.y
# build_project; native.y compile_package and the package objects).
#
# A project is a directory with a y.toml; `ycc build` compiles each package
# it depends on once (DIR/build/obj keeps the objects) and links every
# [bin] into DIR/build. Checks: a diamond of path dependencies builds and
# runs, each package's top level once and dependencies first; names stay
# qualified (a bin's own `sq` is not a package's); records, closures,
# optionals, defaults and string globals cross the boundary, and a
# package's globals are read-only; a rebuild compiles nothing and gives
# the same bytes; a body change recompiles that package only, an
# interface change its importers too; a damaged object, or one another
# compiler wrote, is rebuilt; a fresh build gives the same bytes as a
# cached one, and the C copy the same as ycc; inside a package, std
# modules, relative imports, its src roots, argv and exec work; --no-exec
# and -g reach the packages; errors name the file they are in; every
# manifest, graph and command-line error; git dependencies are fetched,
# pinned in y.lock, and vendored.

source "$(dirname "$0")/lib.sh"

# The built ycc (override with $YSELF, e.g. ./ynew).
YCC="${YSELF:-$ROOT/ycc}"
if [ ! -x "$YCC" ]; then
    echo "error: $YCC not built — run 'make ycc' first" >&2
    exit 2
fi
# The builds run in the projects' directories: absolute compiler paths.
case "$YCC" in /*) ;; *) YCC="$PWD/$YCC" ;; esac
case "$CYCC" in /*) ;; *) CYCC="$PWD/$CYCC" ;; esac

TMPD="$(mktemp -d /tmp/ypkg_test.XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT
CTO=$(( 120 * YTIMEOUT_SCALE ))

mk() { mkdir -p "$(dirname "$1")"; cat >"$1"; }

# yb <compiler> <dir> [args...]: `<compiler> build [args...]` run in <dir>;
# both output streams in $TMPD/out.
yb() {
    local c="$1" d="$2"
    shift 2
    (cd "$d" && timeout "$CTO" "$c" build "$@" </dev/null >"$TMPD/out" 2>&1)
}

# same_text <name> <want> <file>: the file holds exactly <want>.
same_text() {
    if [ "$(cat "$3")" = "$2" ]; then
        pass "$1"
    else
        fail "$1" "want: $(printf '%s' "$2" | head -c 300 | tr '\n' '|')  got: $(head -c 300 "$3" | tr '\n' '|')"
    fi
}

# runs <name> <want> <bin> [args...]: the program prints exactly <want>.
runs() {
    local name="$1" want="$2" bin="$3"
    shift 3
    run_bin 10 "$bin" "$@" </dev/null >"$TMPD/run" 2>&1
    same_text "$name" "$want" "$TMPD/run"
}

# A package object without its key (the compiler's own hash differs
# between ycc and the C copy; the rest must not).
obj_body() { tail -c +12 "$1" | sed '1s/^[0-9]*:[0-9]*-[0-9]*//'; }

# agree <name> <dir> [args...]: a fresh build by ycc and one by the C copy
# print the same and write the same programs and objects.
agree() {
    local name="$1" d="$2"
    shift 2
    rm -rf "$d/build" "$TMPD/agree"
    if ! yb "$YCC" "$d" "$@"; then
        fail "C copy agrees: $name" "ycc: $(head -c 300 "$TMPD/out")"
        return
    fi
    cp "$TMPD/out" "$TMPD/out.y"
    cp -R "$d/build" "$TMPD/agree"
    rm -rf "$d/build"
    if ! yb "$CYCC" "$d" "$@"; then
        fail "C copy agrees: $name" "cycc: $(head -c 300 "$TMPD/out")"
        return
    fi
    local bad="" f
    cmp -s "$TMPD/out" "$TMPD/out.y" || bad="messages differ;"
    for f in "$TMPD/agree"/*; do
        [ -f "$f" ] || continue
        cmp -s "$f" "$d/build/$(basename "$f")" || bad="$bad $(basename "$f") differs;"
    done
    for f in "$TMPD/agree"/obj/*.yo; do
        [ -f "$f" ] || continue
        cmp -s <(obj_body "$f") <(obj_body "$d/build/obj/$(basename "$f")") || bad="$bad obj/$(basename "$f") differs;"
    done
    if [ -z "$bad" ]; then pass "C copy agrees: $name"; else fail "C copy agrees: $name" "$bad"; fi
}

# fails <name> <want-last-line> <dir> [args...]: `ycc build` (or, with
# YCMD=vendor, `ycc vendor`) in <dir> exits 1, its last line <want>; and
# the C copy says the same.
fails() {
    local name="$1" want="$2" d="$3" c st
    shift 3
    for c in "$YCC" "$CYCC"; do
        (cd "$d" && timeout "$CTO" "$c" "${YCMD:-build}" "$@" </dev/null >"$TMPD/out" 2>&1)
        st=$?
        if [ "$st" = 1 ] && [ "$(tail -n 1 "$TMPD/out")" = "$want" ]; then
            pass "$name ($(basename "$c"))"
        else
            fail "$name ($(basename "$c"))" "exit $st, want: $want  got: $(tail -n 3 "$TMPD/out" | tr '\n' '|')"
        fi
    done
}

# ── 1. a diamond: app -> a, b, c; a -> c; b -> c ─────────────────────────
P="$TMPD/p1"
mk "$P/c/y.toml" <<'EOF'
[package]
name = "c"
lib = "lib.y"
EOF
mk "$P/c/lib.y" <<'EOF'
puts("init c\n");
let greeting = "hello";
let count = 3;
def mkpt(x: long, y: long) -> { x: long, y: long } { { x: x, y: y } };
def norm1(p: { x: long, y: long }) -> long { p.x + p.y };
def adder(n: long) -> (long) -> long { def(x: long) -> long { x + n } };
def greet(who: str = "world") -> str { greeting + " " + who };
def maybe(n: long) -> long? { if (n > 0) { some(n) } else { none } };
def shout(s: str) -> str { s.upper() };
def sq(x: long) -> long { x * x };
def dfl(a: long = -3, s: str = "q\"x\t", b: bool = true, ch: byte = c'z', fl: float = -1.5, o?: long) -> str {
    let os = "-";
    if (o != none) { os = tostring(unwrap(o)); 0; } else { 0; };
    tostring(a) + s + tostring(b) + tostring(ch) + tostring(fl) + os
};
EOF
mk "$P/a/y.toml" <<'EOF'
[package]
name = "a"
lib = "a.y"   # a comment

[dependencies]
c = { path = "../c" }
EOF
mk "$P/a/a.y" <<'EOF'
import c;
puts("init a\n");
let doubled = c.count * 2;
def twice(n: long) -> long { c.adder(n)(n) };
def pt() -> { x: long, y: long } { c.mkpt(1, 2) };
EOF
mk "$P/b/y.toml" <<'EOF'
[package]
name = 'b'
lib = "b.y"
[dependencies]
c = { path = "../c/" }
EOF
mk "$P/b/b.y" <<'EOF'
import c;
puts("init b\n");
def hi() -> str { c.greet() + "/" + c.greet("b") };
EOF
mk "$P/app/y.toml" <<'EOF'
# the app
[package]
name = "app"
version = "0.1.0"

[bin]
app = "main.y"
tool = "tool.y"

[dependencies]
a = { path = "../a" }
b = { path = "../b" }
c = { path = "../c" }
EOF
mk "$P/app/main.y" <<'EOF'
import a;
import b;
import c;
puts("main\n");
puts(tostring(a.twice(21)) + "\n");
let p = a.pt();
puts(tostring(c.norm1(p)) + " " + tostring(p.x) + "\n");
puts(b.hi() + "\n");
puts(c.greeting + " " + tostring(c.count) + "\n");
let m = c.maybe(5);
if (m != none) { puts("some " + tostring(unwrap(m)) + "\n"); } else { puts("none\n"); };
def sq(x: long) -> long { x * x * x };
puts(tostring(sq(2)) + " " + tostring(c.sq(2)) + " " + tostring(a.doubled) + "\n");
puts(c.dfl() + "|" + c.dfl(1, "s", false, c'y', 2.5, 9) + "\n");
EOF
mk "$P/app/tool.y" <<'EOF'
import c;
puts("tool " + c.shout(c.greet("t")) + "\n");
EOF
APP_OUT="init c
init a
init b
main
42
3 1
hello world/hello b
hello 3
some 5
8 4 6
-3q\"x	true122-1.500000-|1sfalse1212.5000009"

if yb "$YCC" "$P/app"; then
    same_text "build compiles each package once, dependencies first" "compiling c
compiling a
compiling b
built build/app
built build/tool" "$TMPD/out"
else
    fail "a diamond builds" "$(head -c 300 "$TMPD/out")"
fi
runs "the program runs: each package's top level once, in order" "$APP_OUT" "$P/app/build/app"
runs "a bin that needs only c links only c (and its std unit)" "init c
tool HELLO T" "$P/app/build/tool"

# 2. the object cache
cp "$P/app/build/app" "$TMPD/app.1"
yb "$YCC" "$P/app"
same_text "a rebuild compiles nothing" "built build/app
built build/tool" "$TMPD/out"
if cmp -s "$P/app/build/app" "$TMPD/app.1"; then
    pass "a rebuild gives the same bytes"
else
    fail "a rebuild gives the same bytes"
fi
sed -i 's/{ x + n }/{ n + x }/' "$P/c/lib.y"
yb "$YCC" "$P/app"
same_text "a body change recompiles that package only" "compiling c
built build/app
built build/tool" "$TMPD/out"
echo 'def extra() -> long { 1 };' >>"$P/c/lib.y"
yb "$YCC" "$P/app"
same_text "an interface change recompiles the importers too" "compiling c
compiling a
compiling b
built build/app
built build/tool" "$TMPD/out"
runs "and the program still runs" "$APP_OUT" "$P/app/build/app"
cp "$P/app/build/app" "$TMPD/app.2"
head -c 30 "$P/app/build/obj/c.yo" >"$TMPD/c.yo" && cp "$TMPD/c.yo" "$P/app/build/obj/c.yo"
echo garbage >"$P/app/build/obj/a.yo"
yb "$YCC" "$P/app"
same_text "a damaged object is rebuilt" "compiling c
compiling a
built build/app
built build/tool" "$TMPD/out"
rm -rf "$P/app/build"
yb "$YCC" "$P/app"
if cmp -s "$P/app/build/app" "$TMPD/app.2"; then
    pass "a fresh build gives the same bytes as a cached one"
else
    fail "a fresh build gives the same bytes as a cached one"
fi
agree "the diamond" "$P/app"
if [ "$CYCC" -ef "$YCC" ]; then
    skip "an object another compiler wrote is rebuilt" "\$CYCC is \$YSELF"
else
    yb "$YCC" "$P/app"
    same_text "an object another compiler wrote is rebuilt" "compiling c
compiling a
compiling b
built build/app
built build/tool" "$TMPD/out"
fi
# (an object knows its files by the paths the build saw: from elsewhere,
# they are other paths, and the packages compile again)
mkdir -p "$TMPD/elsewhere"
(cd "$TMPD/elsewhere" && timeout "$CTO" "$YCC" build "$P/app" </dev/null >"$TMPD/out" 2>&1)
grep -v '^compiling ' "$TMPD/out" >"$TMPD/out.b"
same_text "build DIR: paths start at DIR" "built $P/app/build/app
built $P/app/build/tool" "$TMPD/out.b"

# 3. what a bin may not do with a package
mk "$P/app/bad.y" <<'EOF'
import c;
c.count = 5;
c.greeting += "x";
c.count++;
c.nope();
c.greet(1, 2);
EOF
cat >"$P/app/y.toml" <<'EOF'
[package]
name = "app"
[bin]
bad = "bad.y"
[dependencies]
c = { path = "../c" }
EOF
yb "$YCC" "$P/app"
grep -v '^compiling ' "$TMPD/out" >"$TMPD/out.b"
same_text "a package's globals are read-only, its names checked" "bad.y:2:1: error: cannot assign to constant 'c.count'
bad.y:3:12: error: cannot assign to constant 'c.greeting' ('+=')
bad.y:4:8: error: cannot assign to constant 'c.count' ('++')
bad.y:5:7: error: undefined function 'c.nope'
bad.y:6:8: error: 'c.greet' takes 1 args, got 2" "$TMPD/out.b"
cp "$P/c/lib.y" "$TMPD/c.lib"
echo 'def broken() -> long { "s" + 1 };' >>"$P/c/lib.y"
yb "$YCC" "$P/app"
same_text "an error in a package names its file" "compiling c
../c/lib.y:17:1: error: 'broken' body: expected long, got str" "$TMPD/out"
cp "$TMPD/c.lib" "$P/c/lib.y"

# ── 4. inside a package: std, relative and root imports; argv, exec ─────
Q="$TMPD/p2"
mk "$Q/u/y.toml" <<'EOF'
[package]
name = "u"
lib = "src/u.y"
src = ["src", "more"]
description = "utilities"
EOF
mk "$Q/u/src/u.y" <<'EOF'
import struct;
import helper from "./helper.y";
import extra;
def first_arg() -> str { let a = argv(); if (len(a) > 1) { a[1] } else { "none" } };
def run(cmd: str) -> long { exec(cmd) };
def h() -> long { helper.hval() + extra.xval() };
def packed() -> long { len(struct.u32be(7)) };
EOF
mk "$Q/u/src/helper.y" <<'EOF'
def hval() -> long { 40 };
EOF
mk "$Q/u/more/extra.y" <<'EOF'
def xval() -> long { 2 };
EOF
mk "$Q/app/y.toml" <<'EOF'
[package]
name = "app"
lib = "lib/app.y"
[bin]
app = "main.y"
[dependencies]
u = { path = "../u" }
EOF
mk "$Q/app/lib/app.y" <<'EOF'
import u;
def total() -> long { u.h() + 1 };
EOF
mk "$Q/app/main.y" <<'EOF'
import u;
import app;
puts(u.first_arg() + " " + tostring(u.h()) + " " + tostring(app.total()) + " " + tostring(u.packed()) + "\n");
u.run("echo ran");
EOF
if yb "$YCC" "$Q/app"; then
    same_text "a project's own lib is a package too" "compiling u
compiling app
built build/app" "$TMPD/out"
else
    fail "a project with imports inside its packages builds" "$(head -c 300 "$TMPD/out")"
fi
runs "std, relative and root imports, argv and exec inside a package" "xyz 42 43 4
ran" "$Q/app/build/app" xyz
yb "$YCC" "$Q/app" --no-exec
same_text "--no-exec reaches the packages" "compiling u
../u/src/u.y:5:33: error: undefined function 'exec'" "$TMPD/out"
agree "imports inside packages" "$Q/app"
agree "imports inside packages, -g" "$Q/app" -g
if command -v addr2line >/dev/null && command -v nm >/dev/null; then
    a=$(nm "$Q/app/build/app" | awk '$3 == "hval" { print $1 }')
    l=$(addr2line -e "$Q/app/build/app" "0x$a" 2>/dev/null)
    case "$l" in
        */u/src/helper.y:1) pass "-g: a package's code maps to its file ($l)" ;;
        *) fail "-g: a package's code maps to its file" "hval at 0x$a: $l" ;;
    esac
else
    skip "-g: a package's code maps to its file" "no addr2line"
fi

# ── 5. errors: the manifest ──────────────────────────────────────────────
M="$TMPD/m"
mkdir -p "$M"
fails "no manifest" "error: cannot read 'y.toml'" "$M"
manifest() { # manifest <name> <want> <y.toml text>
    printf '%s\n' "$3" >"$M/y.toml"
    fails "$1" "$2" "$M"
}
manifest "unclosed table header" "error: y.toml:1: expected ']' after the table name" '[package'
manifest "an array of tables" "error: y.toml:1: [[package]] has no place in a manifest" '[[package]]'
manifest "a bad table name" "error: y.toml:1: bad table name 'pack age'" '[pack age]'
manifest "a table twice" "error: y.toml:2: table [package] appears twice" '[package]
[package]'
manifest "a line that is no key = value" "error: y.toml:2: expected 'key = value'" '[package]
name'
manifest "a bad key" "error: y.toml:2: bad key 'na me'" '[package]
na me = "x"'
manifest "a key twice" "error: y.toml:3: duplicate key 'name'" '[package]
name = "a"
name = "b"'
manifest "a bare value" "error: y.toml:2: expected a string, an array or an inline table after '='" '[package]
name = x'
manifest "text after the value" "error: y.toml:2: unexpected text after the value" '[package]
name = "a" b'
manifest "an unterminated string" "error: y.toml:2: unterminated string" '[package]
name = "a'
manifest "an unknown escape" "error: y.toml:2: unknown escape '\q' in a string" '[package]
name = "a\q"'
manifest "an array without a comma" "error: y.toml:2: expected ',' or ']' in an array" '[package]
src = ["a" "b"]'
manifest "an array of numbers" "error: y.toml:2: expected a string" '[package]
src = [1]'
manifest "an inline table without a key" "error: y.toml:2: expected a key" '[dependencies]
x = { = "a" }'
manifest "an inline table without '='" "error: y.toml:2: expected '=' after 'path'" '[dependencies]
x = { path "a" }'
manifest "an inline table's key twice" "error: y.toml:2: duplicate key 'path'" '[dependencies]
x = { path = "a", path = "b" }'
manifest "an inline table without a comma" "error: y.toml:2: expected ',' or '}' in an inline table" '[dependencies]
x = { path = "a" git = "b" }'
manifest "an unknown table" "error: y.toml:1: unknown table [nope]" '[nope]'
manifest "a key outside any table" "error: y.toml:1: 'name' is outside any table" 'name = "x"'
manifest "a name that is no string" "error: y.toml:2: 'name' must be a string" '[package]
name = ["a"]'
manifest "no name" "error: y.toml: [package] has no name" '[package]
lib = "l.y"'
manifest "a name that is no identifier" "error: y.toml:2: package name 'my-app' is not an identifier" '[package]
name = "my-app"'
manifest "a name that is a keyword" "error: y.toml:2: package name 'while' is a keyword" '[package]
name = "while"'
manifest "src that is no array" "error: y.toml:3: 'src' must be an array of strings" '[package]
name = "a"
src = "src"'
manifest "an unknown [package] key" "error: y.toml:3: unknown key 'edition' in [package]" '[package]
name = "a"
edition = "1"'
manifest "a bin named obj" "error: y.toml:4: 'obj' cannot name a bin: build/obj is ycc's own" '[package]
name = "a"
[bin]
obj = "m.y"'
manifest "a dependency name that is no identifier" "error: y.toml:4: dependency name 'my-dep' is not an identifier" '[package]
name = "a"
[dependencies]
my-dep = { path = "x" }'
manifest "a dependency name that is a keyword" "error: y.toml:4: dependency name 'let' is a keyword" '[package]
name = "a"
[dependencies]
let = { path = "x" }'
manifest "an unknown dependency key" "error: y.toml:2: unknown key 'tag' in dependency 'x'" '[dependencies]
x = { path = "a", tag = "b" }'
manifest "a version requirement" 'error: y.toml:2: dependency '\''x'\'' must be { path = "..." } or { git = "...", rev = "..." }' '[dependencies]
x = "1.0"'
manifest "a path and a git" "error: y.toml:2: dependency 'x' has both a path and a git" '[dependencies]
x = { path = "a", git = "b" }'
manifest "a rev without a git" "error: y.toml:2: dependency 'x' has a rev but no git" '[dependencies]
x = { path = "a", rev = "b" }'
manifest "nothing to build" "error: y.toml has no [bin] and no lib: nothing to build" '[package]
name = "a"'
manifest "a missing bin" "error: cannot read file 'nope.y'" '[package]
name = "a"
[bin]
x = "nope.y"'
fails "an unknown flag" "ycc: unknown flag '--bogus' (see ycc -h)" "$M" --bogus
fails "two directories" "error: ycc build takes one project directory" "$M" a b
YCMD=vendor fails "vendor: two directories" "error: ycc vendor takes one project directory" "$M" a b

# ── 6. errors: the dependency graph ──────────────────────────────────────
G="$TMPD/g"
mk "$G/c1/y.toml" <<'EOF'
[package]
name = "c"
lib = "c.y"
EOF
echo 'def v() -> long { 1 };' | mk "$G/c1/c.y"
mk "$G/c2/y.toml" <<'EOF'
[package]
name = "c"
lib = "c.y"
EOF
echo 'def v() -> long { 2 };' | mk "$G/c2/c.y"
mk "$G/a/y.toml" <<'EOF'
[package]
name = "a"
lib = "a.y"
[dependencies]
c = { path = "../c1" }
EOF
printf 'import c;\ndef av() -> long { c.v() };\n' | mk "$G/a/a.y"
mk "$G/b/y.toml" <<'EOF'
[package]
name = "b"
lib = "b.y"
[dependencies]
c = { path = "../c2" }
EOF
printf 'import c;\ndef bv() -> long { c.v() };\n' | mk "$G/b/b.y"
mk "$G/nolib/y.toml" <<'EOF'
[package]
name = "nolib"
[bin]
x = "x.y"
EOF
mk "$G/cy1/y.toml" <<'EOF'
[package]
name = "cy1"
lib = "l.y"
[dependencies]
cy2 = { path = "../cy2" }
EOF
mk "$G/cy2/y.toml" <<'EOF'
[package]
name = "cy2"
lib = "l.y"
[dependencies]
cy1 = { path = "../cy1" }
EOF
mkdir -p "$G/app"
printf 'import a;\nimport b;\nputs(tostring(a.av() * 10 + b.bv()) + "\\n");\n' | mk "$G/app/main.y"
graph() { # graph <name> <want> <[dependencies] lines>
    printf '[package]\nname = "app"\n[bin]\napp = "main.y"\n[dependencies]\n%s\n' "$3" >"$G/app/y.toml"
    fails "$1" "$2" "$G/app"
}
graph "a missing dependency" "error: cannot read '../nowhere/y.toml'" 'x = { path = "../nowhere" }'
graph "a dependency that is another package" "error: dependency 'x' (../c1) is package 'c'" 'x = { path = "../c1" }'
graph "a dependency without a lib" "error: package 'nolib' (../nolib) has no lib to import" 'nolib = { path = "../nolib" }'
graph "a cycle" "error: dependency cycle: app -> cy1 -> cy2 -> cy1" 'cy1 = { path = "../cy1" }'
graph "one name from two places" "error: package 'c' comes from two places: ../c1 (for a) and ../c2 (for b)" 'a = { path = "../a" }
b = { path = "../b" }'
printf '[package]\nname = "app"\n[bin]\napp = "main.y"\n[dependencies]\na = { path = "../a" }\nb = { path = "../b" }\nc = { path = "../c2" }\n' >"$G/app/y.toml"
if yb "$YCC" "$G/app"; then
    runs "the project's own dependency settles a name" "22" "$G/app/build/app"
else
    fail "the project's own dependency settles a name" "$(head -c 300 "$TMPD/out")"
fi
echo '[nope]' >"$M/y.toml"
rm -rf "$G/app/build"
touch "$G/app/build"
fails "a build directory that cannot be made" "error: cannot create directory 'build'" "$G/app"
rm -f "$G/app/build"
YCMD=vendor fails "vendor: a broken manifest" "error: y.toml:1: unknown table [nope]" "$M"
(cd "$G/app" && timeout "$CTO" "$YCC" vendor </dev/null >"$TMPD/out" 2>&1)
same_text "vendor: no git dependencies" "nothing to vendor: no git dependencies" "$TMPD/out"

# ── 7. git dependencies ──────────────────────────────────────────────────
if ! command -v git >/dev/null; then
    skip "git dependencies" "no git"
else
    R="$TMPD/repo"
    W="$TMPD/gp"
    # -c user.name/user.email so the throwaway repo needs no identity, and
    # -c commit.gpgsign=false -c tag.gpgsign=false so a developer whose GLOBAL
    # git config signs its commits and tags (commit.gpgsign/tag.gpgsign=true
    # plus user.signingkey) gets neither a pinentry prompt nor, with no tty, a
    # silently unsigned failure: without these the commits below leave an EMPTY
    # repo and the tag never exists, and the git tests blame the compiler. The
    # repo lives in $TMPD, so this project's own local commit.gpgsign=false
    # never reaches it.
    gitc() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false "$@" >/dev/null 2>&1; }
    mkdir -p "$R"
    git -C "$R" init --quiet >/dev/null 2>&1
    printf '[package]\nname = "gl"\nlib = "gl.y"\n' >"$R/y.toml"
    echo 'def v() -> long { 1 };' >"$R/gl.y"
    gitc add -A && gitc commit --quiet -m one && gitc tag v1
    echo 'def v() -> long { 2 };' >"$R/gl.y"
    gitc commit --quiet -am two
    c2=$(git -C "$R" rev-parse HEAD)
    mk "$W/y.toml" <<EOF
[package]
name = "gp"
[bin]
gp = "main.y"
[dependencies]
gl = { git = "$R" }
EOF
    printf 'import gl;\nputs(tostring(gl.v()) + "\\n");\n' | mk "$W/main.y"
    if yb "$YCC" "$W"; then
        same_text "git: fetched, then compiled" "fetching gl ($R)
compiling gl
built build/gp" "$TMPD/out"
        runs "git: the default branch" "2" "$W/build/gp"
    else
        fail "git: a git dependency builds" "$(head -c 300 "$TMPD/out")"
    fi
    if grep -q "^commit = \"$c2\"$" "$W/y.lock" 2>/dev/null && grep -q '^rev = ""$' "$W/y.lock"; then
        pass "git: y.lock pins the commit"
    else
        fail "git: y.lock pins the commit" "$(cat "$W/y.lock" 2>&1 | head -c 300)"
    fi
    echo 'def v() -> long { 3 };' >"$R/gl.y"
    gitc commit --quiet -am three
    yb "$YCC" "$W"
    same_text "git: a pinned dependency is not fetched again" "built build/gp" "$TMPD/out"
    runs "git: ... and stays at its commit" "2" "$W/build/gp"
    rm "$W/y.lock"
    yb "$YCC" "$W"
    same_text "git: without y.lock it moves to the branch's head" "fetching gl ($R)
compiling gl
built build/gp" "$TMPD/out"
    runs "git: ... the new commit" "3" "$W/build/gp"
    sed -i "s|gl = { git = \"$R\" }|gl = { git = \"$R\", rev = \"v1\" }|" "$W/y.toml"
    yb "$YCC" "$W"
    runs "git: a rev" "1" "$W/build/gp"
    if grep -q '^rev = "v1"$' "$W/y.lock"; then pass "git: y.lock records the rev"; else fail "git: y.lock records the rev" "$(cat "$W/y.lock")"; fi
    agree "a git dependency" "$W"
    (cd "$W" && timeout "$CTO" "$YCC" vendor </dev/null >"$TMPD/out" 2>&1)
    same_text "vendor: copies the git dependencies" "vendored gl (vendor/gl)" "$TMPD/out"
    if [ -f "$W/vendor/gl/y.toml" ] && [ ! -e "$W/vendor/gl/.git" ]; then
        pass "vendor: the package without its .git"
    else
        fail "vendor: the package without its .git" "$(ls -a "$W/vendor/gl" 2>&1 | tr '\n' ' ')"
    fi
    rm -rf "$W/build"
    yb "$YCC" "$W"
    same_text "vendor: a vendored dependency is not fetched" "compiling gl
built build/gp" "$TMPD/out"
    runs "vendor: ... and is the one built" "1" "$W/build/gp"
    agree "a vendored dependency" "$W"
    rm -rf "$W/vendor"
    touch "$W/vendor"
    YCMD=vendor fails "vendor: a copy that fails" "error: vendoring 'gl' failed" "$W"
    rm -f "$W/vendor"
    printf '[package]\nname = "gp"\n[bin]\ngp = "main.y"\n[dependencies]\ngl = { git = "%s/nope" }\n' "$TMPD" >"$TMPD/gq.toml"
    mkdir -p "$TMPD/gq" && cp "$TMPD/gq.toml" "$TMPD/gq/y.toml"
    fails "git: a fetch that fails" "error: fetching 'gl' from $TMPD/nope failed" "$TMPD/gq"
fi

print_summary "pkg"
