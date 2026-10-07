#!/bin/bash
# Self-hosted compiler check: ycc must produce binaries that behave exactly
# like the same programs compiled by the reference compiler (refs/ycc.ref).
# Usage: ./test/sh/test_ycc.sh
# Skips (exit 0) if ./ycc is not built; build it with `make ycc`.

source "$(dirname "$0")/lib.sh"   # ROOT, YBOOT, PASS/FAIL/SKIP, colors

# The built ycc (override with $YCC, e.g. the ASan build for make test-asan).
YCC_BIN="${YCC:-$ROOT/ycc}"

echo "═══════════════════════════════════════════"
echo "  ycc self-hosted compiler check"
echo "═══════════════════════════════════════════"
echo ""

if [ ! -x "$YCC_BIN" ]; then
    echo "  (skipped: run 'make ycc' first)"
    echo ""
    echo "═══════════════════════════════════════════"
    echo -e "  Results: 0 passed, 0 failed / 0 total (skipped)"
    echo "═══════════════════════════════════════════"
    exit 0
fi

# Parity: each program compiled by the reference compiler (through the shim)
# must print exactly what the ycc-built binary prints.
for prog in 'def f(n: long) -> long { if (n < 2) { n } else { self(n-1) + self(n-2) } }; print(f(10));' \
            'let m = 0; let i = 1; while (i <= 10) { m = m + i; i = i + 1; }; print(m);' \
            'def add(a: long, b: long) -> long { a + b }; print(add(20, 22));' \
            'def outer() -> long { def h(x: long) -> long { x * 2 }; h(21) }; print(outer());'; do
    echo "$prog" > /tmp/sh.y
    c_out=$(timeout $(( 10 * YTIMEOUT_SCALE )) "$YBOOT" -q /tmp/sh.y </dev/null 2>&1)
    if timeout $(( 120 * YTIMEOUT_SCALE )) "$YCC_BIN" -o /tmp/sh_bin /tmp/sh.y </dev/null >/dev/null 2>&1; then
        y_out=$(run_bin 10 /tmp/sh_bin </dev/null 2>&1)
    else
        y_out="(ycc failed)"
    fi
    rm -f /tmp/sh.y /tmp/sh_bin
    if [ "$c_out" = "$y_out" ]; then
        echo -e "${GREEN}PASS${NC} self-hosted: $(echo "$prog" | cut -c1-40)..."
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} self-hosted: $(echo "$prog" | cut -c1-40)..."
        echo "  reference: $c_out"
        echo "  self-built ycc: $y_out"
        FAIL=$((FAIL + 1))
    fi
done

# test/y/examples/ysh.y's `eval` shells out to the `ycc` next to the ysh
# binary; the examples suite runs ysh with stdin at EOF, so this is the
# only place it is driven.
YSH_DIR=$(mktemp -d /tmp/ysh_test.XXXXXX)
ln -s "$YCC_BIN" "$YSH_DIR/ycc"
if timeout $(( 120 * YTIMEOUT_SCALE )) "$YCC_BIN" -o "$YSH_DIR/ysh" "$ROOT/test/y/examples/ysh.y" </dev/null >/dev/null 2>&1; then
    ysh_out=$(timeout $(( 60 * YTIMEOUT_SCALE )) "$YSH_DIR/ysh" -c 'eval print(6 * 7)' </dev/null 2>&1)
    ysh_bad=$(timeout $(( 60 * YTIMEOUT_SCALE )) "$YSH_DIR/ysh" -c 'eval exec("true")' </dev/null 2>&1)
else
    ysh_out="(ycc failed on ysh.y)"
    ysh_bad=""
fi
rm -rf "$YSH_DIR"
if [ "$ysh_out" = "42" ]; then
    echo -e "${GREEN}PASS${NC} ysh eval compiles and runs through ycc"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC} ysh eval compiles and runs through ycc"
    echo "  got: $(echo "$ysh_out" | head -c 300)"
    FAIL=$((FAIL + 1))
fi
if echo "$ysh_bad" | grep -q "undefined function 'exec'" &&
   echo "$ysh_bad" | grep -q "compile failed"; then
    echo -e "${GREEN}PASS${NC} ysh eval compiles with --no-exec"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC} ysh eval compiles with --no-exec"
    echo "  got: $(echo "$ysh_bad" | head -c 300)"
    FAIL=$((FAIL + 1))
fi

# Warnings (lint.y): on stderr, an import's as its path from the main
# file's directory, the main file's own bare; the build goes on. -w drops
# them without changing a byte, and -S keeps them out of the listing. The
# self-hosted compiler and the C copy print the same.
WARN_DIR=$(mktemp -d /tmp/ycc_warn.XXXXXX)
mkdir "$WARN_DIR/sub"
printf 'def f(x: long) -> long {\n    let u = 1;\n    x\n};\nexport { f };\n' > "$WARN_DIR/sub/lib.y"
printf 'import lib from "./sub/lib.y";\ndef g() -> long {\n    let v = 2;\n    lib.f(3)\n};\nprint(g());\n' > "$WARN_DIR/main.y"
want_warn="sub/lib.y:2:5: warning: unused variable 'u'
3:5: warning: unused variable 'v'"
for compiler in "$YCC_BIN" "$CYCC"; do
    tag="${compiler##*/}"
    rm -f "$WARN_DIR/a.out" "$WARN_DIR/w.out"
    out=$(cd "$WARN_DIR" && timeout $(( 120 * YTIMEOUT_SCALE )) "$compiler" -o a.out main.y </dev/null 2>"$WARN_DIR/err")
    ec=$?
    got=$(cat "$WARN_DIR/err")
    run=$(run_bin 10 "$WARN_DIR/a.out" </dev/null 2>&1)
    if [ $ec -eq 0 ] && [ -z "$out" ] && [ "$got" = "$want_warn" ] && [ "$run" = 3 ]; then
        pass "warnings on stderr, the build goes on ($tag)"
    else
        fail "warnings on stderr, the build goes on ($tag)" \
            "exit=$ec, stdout '$out', stderr '$(echo "$got" | tr '\n' '|')', run '$run'"
    fi
    out=$(cd "$WARN_DIR" && timeout $(( 120 * YTIMEOUT_SCALE )) "$compiler" -w -o w.out main.y </dev/null 2>&1)
    ec=$?
    if [ $ec -eq 0 ] && [ -z "$out" ] && cmp -s "$WARN_DIR/a.out" "$WARN_DIR/w.out"; then
        pass "-w: no warnings, the same bytes ($tag)"
    else
        fail "-w: no warnings, the same bytes ($tag)" "exit=$ec, output '$(echo "$out" | tr '\n' '|')'"
    fi
    out=$(cd "$WARN_DIR" && timeout $(( 120 * YTIMEOUT_SCALE )) "$compiler" -S main.y </dev/null 2>"$WARN_DIR/err")
    ec=$?
    got=$(cat "$WARN_DIR/err")
    if [ $ec -eq 0 ] && [ -n "$out" ] && ! grep -q 'warning' <<< "$out" && [ "$got" = "$want_warn" ]; then
        pass "-S: the listing on stdout, warnings on stderr ($tag)"
    else
        fail "-S: the listing on stdout, warnings on stderr ($tag)" \
            "exit=$ec, stderr '$(echo "$got" | tr '\n' '|')'"
    fi
done
rm -rf "$WARN_DIR"

# A compiler found through PATH resolves its std units from /proc/self/exe,
# not from argv()[0] -- which is then just "ycc", naming no directory. A
# checkout reached by bare name (std in src/y/std beside the binary) and an
# installed copy with std/ beside it both have to find fs, and both copies of
# the compiler have to agree. Run from a neutral cwd, so nothing can be picked
# up out of the source tree by accident.
PATH_DIR=$(mktemp -d /tmp/ycc_path.XXXXXX)
mkdir -p "$PATH_DIR/work"
printf 'import fs;\nprint(fs.exists("/tmp"));\n' > "$PATH_DIR/work/prog.y"
for compiler in "$YCC_BIN" "$CYCC"; do
    tag="${compiler##*/}"
    bindir=$(dirname "$compiler")
    # (a) the compiler's own directory on PATH, bare name, neutral cwd: in a
    # checkout std/ lives at src/y/std beside the binary
    out=$(cd "$PATH_DIR/work" && PATH="$bindir:$PATH" timeout $(( 120 * YTIMEOUT_SCALE )) \
        "$(basename "$compiler")" prog.y -o out </dev/null 2>&1)
    ec=$?
    run=$(run_bin 10 "$PATH_DIR/work/out" </dev/null 2>&1)
    if [ $ec -eq 0 ] && [ -z "$out" ] && [ "$run" = true ]; then
        pass "std units found through PATH in a checkout ($tag)"
    else
        fail "std units found through PATH in a checkout ($tag)" \
            "exit=$ec, output '$(printf '%s' "$out" | tr '\n' '|')', run '$run'"
    fi
    # (b) an installed copy with std/ beside it
    install="$PATH_DIR/install-$tag"
    mkdir -p "$install"
    cp "$compiler" "$install/ycc-installed"
    cp -r "$ROOT/src/y/std" "$install/std"
    rm -f "$PATH_DIR/work/out"
    out=$(cd "$PATH_DIR/work" && PATH="$install:$PATH" timeout $(( 120 * YTIMEOUT_SCALE )) \
        ycc-installed prog.y -o out </dev/null 2>&1)
    ec=$?
    run=$(run_bin 10 "$PATH_DIR/work/out" </dev/null 2>&1)
    if [ $ec -eq 0 ] && [ -z "$out" ] && [ "$run" = true ]; then
        pass "std units found through PATH beside the binary ($tag)"
    else
        fail "std units found through PATH beside the binary ($tag)" \
            "exit=$ec, output '$(printf '%s' "$out" | tr '\n' '|')', run '$run'"
    fi
    # and the same binary with the checkout's directory behind it on PATH, so
    # the module it finds is the one next to it
    rm -f "$PATH_DIR/work/out"
    out=$(cd "$PATH_DIR/work" && PATH="$install:$bindir:$PATH" timeout $(( 120 * YTIMEOUT_SCALE )) \
        ycc-installed prog.y -o out </dev/null 2>&1)
    ec=$?
    run=$(run_bin 10 "$PATH_DIR/work/out" </dev/null 2>&1)
    if [ $ec -eq 0 ] && [ -z "$out" ] && [ "$run" = true ]; then
        pass "an installed copy prefers its own std ($tag)"
    else
        fail "an installed copy prefers its own std ($tag)" \
            "exit=$ec, output '$(printf '%s' "$out" | tr '\n' '|')', run '$run'"
    fi
done
rm -rf "$PATH_DIR"

# Driver failures: each diagnostic must be identical in the self-hosted
# compiler and its C copy, and each compiler must exit with status 1.
expect_cli_error() {
    local name="$1" expected="$2"
    shift 2
    local compiler output ec
    for compiler in "$YCC_BIN" "$CYCC"; do
        output=$(timeout $(( 120 * YTIMEOUT_SCALE )) "$compiler" "$@" </dev/null 2>&1)
        ec=$?
        if [ "$ec" -eq 1 ] && grep -Fqx -- "$expected" <<< "$output"; then
            pass "CLI error $name (${compiler##*/})"
        else
            fail "CLI error $name (${compiler##*/})" \
                "exit=$ec, expected '$expected', got: $(printf '%s' "$output" | tr '\n' '|')"
        fi
    done
}

expect_cli_error "unknown flag" "ycc: unknown flag '--bad' (see ycc -h)" --bad
expect_cli_error "-o with an empty path" "ycc: -o needs a path, got ''" \
    -o "" "$ROOT/test/y/native/t01_arith.y"
expect_cli_error "-W without a level" "ycc: -W needs a warning level (0, 1 or 2)" \
    -o /tmp/ycc_wlevel.out "$ROOT/test/y/native/t01_arith.y" -W
expect_cli_error "-W with a bad level" "ycc: -W needs a warning level (0, 1 or 2), got 'x'" \
    -W x -o /tmp/ycc_wlevel.out "$ROOT/test/y/native/t01_arith.y"
expect_cli_error "-W above 2" "ycc: -W needs a warning level (0, 1 or 2), got '3'" \
    -W 3 -o /tmp/ycc_wlevel.out "$ROOT/test/y/native/t01_arith.y"
expect_cli_error "-W that would wrap the scan" \
    "ycc: -W needs a warning level (0, 1 or 2), got '99999999999999999999'" \
    -W 99999999999999999999 -o /tmp/ycc_wlevel.out "$ROOT/test/y/native/t01_arith.y"
# --target: the one global the whole compiler branches on (target.y), written
# before anything reads it. Both spellings are accepted and both are checked,
# because a flag that works in one form and not the other is a flag nobody can
# rely on.
# ...with the flag LAST, which is the only way to reach the "needs a name"
# branch: anything after --target is its name, so `--target -o out` is an
# unknown TARGET called -o, not a missing one.
expect_cli_error "--target without a name" "ycc: --target needs a name (linux, windows)" \
    -o /tmp/ycc_target.out "$ROOT/test/y/native/t01_arith.y" --target
expect_cli_error "--target with an unknown name" "ycc: unknown target 'plan9' (linux, windows, kernel)" \
    --target=plan9 -o /tmp/ycc_target.out "$ROOT/test/y/native/t01_arith.y"
expect_cli_error "no input file" "error: no input file (see ycc -h)"
expect_cli_error "multiple input files" "error: ycc compiles one program; use imports to combine files" \
    "$ROOT/test/y/native/t01_arith.y" "$ROOT/test/y/native/t02_recursion.y"
expect_cli_error "cannot read input" "error: cannot read file '/no-such-cov-ycc-input.y'" \
    /no-such-cov-ycc-input.y
# A directory opens for reading but read(2) refuses it, so it used to read as
# "" and compile into an empty executable. fs.read_file now answers none for
# one (std/fs.y read_bytes).
expect_cli_error "input is a directory" "error: cannot read file '/tmp'" /tmp
expect_cli_error "assembly write failure" "error: writing '/nonexistent/dir/out' failed" \
    -S -o /nonexistent/dir/out "$ROOT/test/y/native/t01_arith.y"
expect_cli_error "executable write failure" "error: writing '/nonexistent/dir/out' failed" \
    -o /nonexistent/dir/out "$ROOT/test/y/native/t01_arith.y"

# Import depth: a chain of 33 nested imports is fatal. Only a chain reaches
# the limit -- the resolver's `seen` list stops a cycle first.
DEPTH_DIR=$(mktemp -d /tmp/ycc_depth.XXXXXX)
for i in $(seq 0 31); do
    echo "import d$((i + 1));" > "$DEPTH_DIR/d$i.y"
done
: > "$DEPTH_DIR/d32.y"
printf 'import d0;\nprint("unreachable");\n' > "$DEPTH_DIR/main.y"
expect_cli_error "import depth" "error: native import depth exceeded (cycle?)" \
    -o "$DEPTH_DIR/a.out" "$DEPTH_DIR/main.y"
rm -rf "$DEPTH_DIR"

# The compiler running out of memory must look the same from both copies: the
# same text, on the same stream, with the same status. The port gate cannot see
# this -- it compares output, not exits -- and lib.sh's 3.5 GB cap never gets
# near an allocation failure, so the case brings its own ulimit and its own
# input: 120 000 tiny functions need well over 400 MB to check and emit.
# 400 MB leaves a dynamically linked cycc enormous headroom, so this fails in
# the allocator rather than in the loader on any machine.
OOM_DIR=$(mktemp -d /tmp/ycc_oom.XXXXXX)
{
    for i in $(seq 0 119999); do
        echo "def f$i(a: long) -> long { let s = 0; s += a; s * 2; }"
    done
    echo 'print(f0(1));'
} > "$OOM_DIR/big.y"
oom_seen=0
for compiler in "$YCC_BIN" "$CYCC"; do
    oom_out=$( (ulimit -S -v 409600; timeout $(( 120 * YTIMEOUT_SCALE )) "$compiler" \
        -o "$OOM_DIR/big.bin" "$OOM_DIR/big.y" </dev/null) 2>"$OOM_DIR/err" )
    oom_ec=$?
    if [ "$oom_ec" -eq 1 ] && [ "$oom_out" = "runtime error: out of memory" ] \
        && [ ! -s "$OOM_DIR/err" ]; then
        oom_seen=$((oom_seen + 1))
    else
        fail "OOM report (${compiler##*/})" \
            "exit=$oom_ec, out='$oom_out', err='$(cat "$OOM_DIR/err")'"
    fi
done
[ "$oom_seen" -eq 2 ] && pass "OOM report identical from both copies"
rm -rf "$OOM_DIR"

# A fifo is not seekable: there is no size to ask for, so the whole-file path
# (fseek/ftell) cannot be used and the stream has to be read to its end. The Y
# copy always managed `ycc <(cat prog.y)`; the C copy's ftell answered -1 and it
# reported "cannot read file" instead. One fifo per compiler -- a second reader
# would block with no writer to feed it -- and the two assemblies must match.
fifo_asm() {
    local d
    d=$(mktemp -d /tmp/ycc_fifo.XXXXXX)
    mkfifo "$d/in.y"
    (cat "$ROOT/test/y/native/t01_arith.y" > "$d/in.y" &)
    timeout $(( 60 * YTIMEOUT_SCALE )) "$1" -S "$d/in.y" -o "$2" </dev/null
    local ec=$?
    rm -rf "$d"
    return $ec
}
fifo_ec=0
for compiler in "$YCC_BIN" "$CYCC"; do
    if fifo_asm "$compiler" "/tmp/ycc_fifo_$(basename "$compiler").s"; then
        fifo_ec=$((fifo_ec + 1))
    else
        fail "read a fifo (${compiler##*/})" "exit $? from -S on a fifo"
    fi
done
if [ "$fifo_ec" -eq 2 ] && cmp -s "/tmp/ycc_fifo_$(basename "$YCC_BIN").s" \
    "/tmp/ycc_fifo_$(basename "$CYCC").s"; then
    pass "fifo read identical from both copies"
fi
rm -f /tmp/ycc_fifo_*.s

# `ycc -E` (ideas/meta.md, "Debuggability") dumps the source the lexer sees,
# with origin markers as comments. It has to be usable: re-compiling the dump
# gives the same binary, and a dump of a file with a meta block holds the
# GENERATED text -- including any `#{` inside a literal, which the pass never
# rescans.
meta_dump() {
    local prog="$1" tag="$2" dir ec
    dir=$(mktemp -d /tmp/ycc_meta_XXXXXX)
    timeout $(( 120 * YTIMEOUT_SCALE )) "$YCC_BIN" "$prog" -o "$dir/a" \
        >"$dir/a.err" 2>&1 </dev/null
    if [ $? -ne 0 ]; then
        fail "$tag compile" "$(head -c 200 "$dir/a.err" | tr '\n' '|')"
        rm -rf "$dir"
        return
    fi
    timeout $(( 120 * YTIMEOUT_SCALE )) "$YCC_BIN" -E "$prog" >"$dir/dump.y" 2>/dev/null </dev/null
    ec=$?
    if [ $ec -ne 0 ]; then
        fail "$tag -E" "exit $ec"
        rm -rf "$dir"
        return
    fi
    timeout $(( 120 * YTIMEOUT_SCALE )) "$YCC_BIN" "$dir/dump.y" -o "$dir/b" \
        >"$dir/b.err" 2>&1 </dev/null
    ec=$?
    if [ $ec -ne 0 ]; then
        fail "$tag recompile the dump" "$(head -c 200 "$dir/b.err" | tr '\n' '|')"
        rm -rf "$dir"
        return
    fi
    if cmp -s "$dir/a" "$dir/b"; then
        pass "$tag: recompiling the -E dump gives the same bytes"
    else
        fail "$tag roundtrip" "the binary from the dump differs"
    fi
    rm -rf "$dir"
}
meta_dump "$ROOT/test/y/native/t01_arith.y" "-E dump"
# A meta file whose TOP LEVEL PRINTS NOTHING, and that is the point: the
# generator is the file's own top level, so a top-level print in a meta file
# writes to ycc's stdout before the dump (the "top level runs twice" of
# ideas/meta.md, which lint warns about and t199 checks). t197 has only
# declarations and one block.
meta_dump "$ROOT/test/y/native/t197_meta_field_name_ok.y" "-E dump of a meta file"
# and one with a MID-TOKEN block, where the dump holds generated text the
# scanner must never read again (ideas/meta.md, "the two cases")
meta_dump "$ROOT/test/y/native/t200_meta_mid_token.y" "-E dump of a mid-token meta file"

# `ycc run FILE -- ARG...`: everything after `--` is the program's own argv,
# verbatim, so a test can drive argv without the driver reading the program's
# flags as its own. argv[0] is the source path the run was asked for.
run_args() {
    local compiler="$1" tag="$2" dir out
    dir=$(mktemp -d /tmp/ycc_run.XXXXXX)
    printf 'let a = argv();\nprint(tostring(len(a)));\nlet i = 1;\nwhile (i < len(a)) { print(a[i]); i = i + 1; };\n' > "$dir/p.y"
    out=$(cd "$dir" && timeout $((60 * YTIMEOUT_SCALE)) "$compiler" run p.y -- one "two three" </dev/null 2>&1)
    if [ "$out" = "3
one
two three" ]; then
        pass "run -- passes the program its argv ($tag)"
    else
        fail "run -- passes the program its argv ($tag)" "got '$(printf '%s' "$out" | tr '\n' '|')'"
    fi
    rm -rf "$dir"
}
for compiler in "$YCC_BIN" "$CYCC"; do
    [ -x "$compiler" ] && run_args "$compiler" "${compiler##*/}"
done

# heap_used() must not move with how the caller spelled the command: the
# prologue's heap copy of argv is what it used to count, so an absolute figure
# grew a byte per character of argv[0] (SUGGESTIONS.md 24) and an example's
# golden failed only when the gate ran the binary by absolute path. One
# binary, three spellings, one number.
run_heap_paths() {
    local compiler="$1" tag="$2" dir a b c long
    dir=$(mktemp -d /tmp/ycc_heap.XXXXXX)
    printf 'print(heap_used());\n' > "$dir/p.y"
    (cd "$dir" && timeout $((60 * YTIMEOUT_SCALE)) "$compiler" p.y -o p </dev/null >/dev/null 2>&1)
    if [ ! -x "$dir/p" ]; then
        fail "heap_used -- does not move with argv[0] ($tag)" "no binary"
        rm -rf "$dir"
        return
    fi
    a=$(cd "$dir" && ./p </dev/null)
    b=$(cd "$dir" && ./p </dev/null)
    c=$("$dir/p" </dev/null)
    long=$(printf 'x%.0s' $(seq 1 90))
    cp "$dir/p" "$dir/$long"
    d=$("$dir/$long" </dev/null)
    if [ "$a" = "$b" ] && [ "$a" = "$c" ] && [ "$a" = "$d" ]; then
        pass "heap_used -- same number as ./, by absolute path and a 90-char name ($tag): $a"
    else
        fail "heap_used -- does not move with argv[0] ($tag)" "./=$a abs=$c long=$d"
    fi
    rm -rf "$dir"
}
for compiler in "$YCC_BIN" "$CYCC"; do
    [ -x "$compiler" ] && run_heap_paths "$compiler" "${compiler##*/}"
done

echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} / $TOTAL total"
echo "═══════════════════════════════════════════"

[ $FAIL -eq 0 ] && exit 0 || exit 1
