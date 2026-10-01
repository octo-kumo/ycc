#!/bin/bash
# test/sh/test_debug.sh — `ycc -g` (symbol table + section headers).
#
# -g must not change what runs: the code, rodata and every address match
# the plain build — it only appends .symtab/.strtab/.shstrtab and section
# headers past the loaded image and backs the head of the .bss with file
# zeros (valgrind needs a file-backed read+write mapping). Checks: both
# compilers agree byte for byte, the program behaves the same, the
# loaded bytes match the plain build, and the standard tools (readelf,
# nm, addr2line; gdb and valgrind when installed) see the functions.

source "$(dirname "$0")/lib.sh"

# The built ycc (override with $YCC, e.g. the ASan build for make test-asan).
YCC="${YCC:-$ROOT/ycc}"
if [ ! -x "$YCC" ]; then
    echo "error: $YCC not built — run 'make ycc' first" >&2
    exit 2
fi

TMPD="$(mktemp -d /tmp/ydebug_test.XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

cat >"$TMPD/p.y" <<'EOF'
let calls = 0;

def leaf(n: long) -> long {
    calls = calls + 1;
    n * 2
};

def mid(n: long) -> long {
    leaf(n) + leaf(n + 1)
};

print(mid(5));
print(mid(6));
print(calls);
EOF
printf '22\n26\n4\n' >"$TMPD/want.out"

CTO=$(( 120 * YTIMEOUT_SCALE ))
build() { # build <compiler> <out> [flags...]
    local cc="$1" out="$2"
    shift 2
    timeout "$CTO" "$cc" "$@" -o "$out" "$TMPD/p.y" </dev/null >"$TMPD/cc.err" 2>&1
}
build "$YCC" "$TMPD/plain" || { fail "compile" "ycc: $(head -c 300 "$TMPD/cc.err")"; print_summary "debug"; exit 1; }
build "$YCC" "$TMPD/dbg" -g || { fail "compile -g" "ycc -g: $(head -c 300 "$TMPD/cc.err")"; print_summary "debug"; exit 1; }

# 1. the two compilers agree on -g output, byte for byte
if build "$CYCC" "$TMPD/dbg_c" -g && cmp -s "$TMPD/dbg" "$TMPD/dbg_c"; then
    pass "cycc -g and ycc -g emit identical binaries"
else
    fail "cycc -g and ycc -g emit identical binaries" "$(head -c 300 "$TMPD/cc.err")"
fi

# 2. -g changes nothing that runs
"$TMPD/dbg" </dev/null >"$TMPD/dbg.out" 2>&1
ec=$?
if [ $ec -eq 0 ] && cmp -s "$TMPD/dbg.out" "$TMPD/want.out"; then
    pass "-g build runs the same"
else
    fail "-g build runs the same" "exit $ec: $(head -c 200 "$TMPD/dbg.out" | tr '\n' '|')"
fi

# e_phnum (2 bytes at 56) gives the header size: code starts at 64+56*phnum.
le16() { od -An -t u2 -j "$2" -N 2 "$1" | tr -d ' '; }
phnum=$(le16 "$TMPD/plain" 56)
code_off=$(( 64 + 56 * phnum ))
n=$(stat -c %s "$TMPD/plain")
if cmp -s <(head -c 40 "$TMPD/plain") <(head -c 40 "$TMPD/dbg") \
    && cmp -s <(tail -c +$(( code_off + 1 )) "$TMPD/plain") \
              <(head -c "$n" "$TMPD/dbg" | tail -c +$(( code_off + 1 ))); then
    pass "code and rodata identical to the plain build"
else
    fail "code and rodata identical to the plain build" "the loaded bytes differ"
fi

if [ "$(le16 "$TMPD/plain" 60)" = "0" ]; then
    pass "plain build has no section headers"
else
    fail "plain build has no section headers" "e_shnum=$(le16 "$TMPD/plain" 60)"
fi

# 3. the symbol table, as the binutils see it
if ! command -v readelf >/dev/null 2>&1; then
    skip "readelf checks" "readelf not installed"
else
    if readelf -a -W "$TMPD/dbg" >"$TMPD/re.out" 2>"$TMPD/re.err" && [ ! -s "$TMPD/re.err" ]; then
        pass "readelf accepts the -g binary"
    else
        fail "readelf accepts the -g binary" "$(head -c 300 "$TMPD/re.err")"
    fi
    secs=$(readelf -S -W "$TMPD/dbg" | grep -oE '\.(text|rodata|bss|symtab|strtab|shstrtab) ' | tr -d ' ' | tr '\n' ' ')
    if [ "$secs" = ".text .rodata .bss .symtab .strtab .shstrtab " ]; then
        pass "sections .text .rodata .bss .symtab .strtab .shstrtab"
    else
        fail "sections .text .rodata .bss .symtab .strtab .shstrtab" "got: $secs"
    fi
    # Num: Value Size Type Bind Vis Ndx Name
    sym() { readelf -s -W "$TMPD/dbg" | awk -v n="$1" '$8 == n { print $4, $5, ($3 > 0 ? "sized" : "empty") }'; }
    for spec in "leaf:FUNC LOCAL sized" "mid:FUNC LOCAL sized" "_start:FUNC GLOBAL sized" \
                "calls:OBJECT LOCAL sized"; do
        name="${spec%%:*}"; want="${spec#*:}"
        got="$(sym "$name" | head -1)"
        if [ "$got" = "$want" ]; then
            pass "symbol $name: $want"
        else
            fail "symbol $name: $want" "got '${got:-<absent>}'"
        fi
    done
    if readelf -s -W "$TMPD/dbg" | grep -qE 'yfn_|yg_|\$[0-9]'; then
        fail "symbol names are the source names" "raw labels leaked into .symtab"
    else
        pass "symbol names are the source names"
    fi
fi

if command -v nm >/dev/null 2>&1 && command -v addr2line >/dev/null 2>&1; then
    addr=$(nm "$TMPD/dbg" | awk '$3 == "leaf" { print $1 }')
    got=$(addr2line -f -e "$TMPD/dbg" "0x$addr" 2>/dev/null | head -1)
    if [ -n "$addr" ] && [ "$got" = "leaf" ]; then
        pass "nm/addr2line resolve leaf"
    else
        fail "nm/addr2line resolve leaf" "addr '$addr' -> '$got'"
    fi
else
    skip "nm/addr2line" "binutils not installed"
fi

# 4. debuggers and profilers name the functions
if command -v gdb >/dev/null 2>&1; then
    timeout 60 gdb -batch -nx -ex "set debuginfod enabled off" -ex "break leaf" -ex run -ex bt \
        "$TMPD/dbg" </dev/null >"$TMPD/gdb.out" 2>&1
    if grep -qE '^#0 .* in leaf \(\)' "$TMPD/gdb.out" && grep -qE '^#1 .* in mid \(\)' "$TMPD/gdb.out"; then
        pass "gdb breaks in leaf, called from mid"
    else
        fail "gdb breaks in leaf, called from mid" "$(grep -E '^#|Breakpoint' "$TMPD/gdb.out" | head -4 | tr '\n' '|')"
    fi
else
    skip "gdb" "gdb not installed"
fi

if command -v valgrind >/dev/null 2>&1 && command -v callgrind_annotate >/dev/null 2>&1; then
    timeout 120 valgrind --tool=callgrind --callgrind-out-file="$TMPD/cg.out" "$TMPD/dbg" \
        </dev/null >"$TMPD/vg.out" 2>"$TMPD/vg.err"
    callgrind_annotate "$TMPD/cg.out" >"$TMPD/cga.out" 2>&1
    if cmp -s "$TMPD/vg.out" "$TMPD/want.out" && grep -qE ':leaf ' "$TMPD/cga.out" \
        && grep -qE ':mid ' "$TMPD/cga.out"; then
        pass "callgrind names leaf and mid"
    else
        fail "callgrind names leaf and mid" "$(grep -E '^ *[0-9,]+ \(' "$TMPD/cga.out" | head -4 | tr '\n' '|')"
    fi
else
    skip "callgrind" "valgrind not installed"
fi

# 5. a program with no .bss still gets a valid symbol table
printf 'exit(3);\n' >"$TMPD/q.y"
if timeout "$CTO" "$YCC" -g -o "$TMPD/q" "$TMPD/q.y" </dev/null >/dev/null 2>&1; then
    "$TMPD/q" </dev/null >/dev/null 2>&1
    ec=$?
    if [ $ec -eq 3 ] && { ! command -v readelf >/dev/null 2>&1 \
            || { readelf -a -W "$TMPD/q" >/dev/null 2>"$TMPD/q.err" && [ ! -s "$TMPD/q.err" ]; }; }; then
        pass "-g on a minimal program"
    else
        fail "-g on a minimal program" "exit $ec $(head -c 200 "$TMPD/q.err" 2>/dev/null)"
    fi
else
    fail "-g on a minimal program" "ycc -g failed"
fi

print_summary "debug"
