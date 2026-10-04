#!/bin/bash
# test/sh/test_debug.sh — `ycc -g` (symbol table, section headers and
# DWARF line info).
#
# -g must not change what runs: the code, rodata and every address match
# the plain build — it only appends .symtab/.strtab/.shstrtab, the line
# table (.debug_info/.debug_abbrev/.debug_line) and section headers past
# the loaded image and backs the head of the .bss with file zeros
# (valgrind needs a file-backed read+write mapping). Checks: both
# compilers agree byte for byte, the program behaves the same, the
# loaded bytes match the plain build, and the standard tools (readelf,
# nm, addr2line, as; gdb and valgrind when installed) see the functions
# and map code to file:line, an imported module's included.

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

# m.y calls into an imported module: the line table names both files
cat >"$TMPD/lib.y" <<'EOF'
def twice(n: long) -> long {
    let r = n * 2;
    r
};
export { twice };
EOF
printf 'import lib from "./lib.y";\nprint(lib.twice(21));\n' >"$TMPD/m.y"

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
if timeout "$CTO" "$YCC" -g -o "$TMPD/m" "$TMPD/m.y" </dev/null >"$TMPD/cc.err" 2>&1 \
    && timeout "$CTO" "$CYCC" -g -o "$TMPD/m_c" "$TMPD/m.y" </dev/null >>"$TMPD/cc.err" 2>&1 \
    && cmp -s "$TMPD/m" "$TMPD/m_c" && [ "$("$TMPD/m" </dev/null 2>&1)" = "42" ]; then
    pass "-g with an import: both compilers agree, it runs"
else
    fail "-g with an import: both compilers agree, it runs" "$(head -c 300 "$TMPD/cc.err")"
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

# 3. the symbol table and the line table, as the binutils see them
if ! command -v readelf >/dev/null 2>&1; then
    skip "readelf checks" "readelf not installed"
else
    if readelf -a -W --debug-dump=info,abbrev,line "$TMPD/dbg" >"$TMPD/re.out" 2>"$TMPD/re.err" \
        && [ ! -s "$TMPD/re.err" ]; then
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
    dsecs=$(readelf -S -W "$TMPD/dbg" | grep -oE '\.debug_[a-z]+ ' | tr -d ' ' | tr '\n' ' ')
    if [ "$dsecs" = ".debug_info .debug_abbrev .debug_line " ]; then
        pass "sections .debug_info .debug_abbrev .debug_line"
    else
        fail "sections .debug_info .debug_abbrev .debug_line" "got: $dsecs"
    fi
    # a row per statement and per function entry (line 0: _start's entry)
    rows=$(readelf --debug-dump=decodedline "$TMPD/dbg" 2>/dev/null \
        | awk '$1 == "p.y" && $2 ~ /^[0-9]+$/ { print $2 }' | sort -nu | tr '\n' ' ')
    if [ "$rows" = "0 1 3 4 5 8 9 12 13 14 " ]; then
        pass "line table rows for p.y lines 1 3 4 5 8 9 12 13 14"
    else
        fail "line table rows for p.y lines 1 3 4 5 8 9 12 13 14" "got: $rows"
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
    got=$(addr2line -e "$TMPD/dbg" "0x$addr" 2>/dev/null | head -1)
    if [ -n "$addr" ] && [ "$got" = "$TMPD/p.y:3" ]; then
        pass "addr2line puts leaf at p.y:3"
    else
        fail "addr2line puts leaf at p.y:3" "addr '$addr' -> '$got'"
    fi
    taddr=$(nm "$TMPD/m" 2>/dev/null | awk '$3 == "twice" { print $1 }')
    got=$(addr2line -e "$TMPD/m" "0x$taddr" 2>/dev/null | head -1)
    if [ -n "$taddr" ] && [ "$got" = "$TMPD/lib.y:1" ]; then
        pass "addr2line puts the imported twice at lib.y:1"
    else
        fail "addr2line puts the imported twice at lib.y:1" "addr '$taddr' -> '$got'"
    fi
else
    skip "nm/addr2line" "binutils not installed"
fi

# 4. debuggers and profilers name the functions and lines
if command -v gdb >/dev/null 2>&1; then
    timeout 60 gdb -batch -nx -ex "set debuginfod enabled off" -ex "break leaf" -ex run -ex bt \
        "$TMPD/dbg" </dev/null >"$TMPD/gdb.out" 2>&1
    # frame #0 shows no address when it stopped on the start of a line
    if grep -qE '^#0 +(0x[0-9a-f]+ in )?leaf \(\)' "$TMPD/gdb.out" && grep -qE '^#1 .* in mid \(\)' "$TMPD/gdb.out"; then
        pass "gdb breaks in leaf, called from mid"
    else
        fail "gdb breaks in leaf, called from mid" "$(grep -E '^#|Breakpoint' "$TMPD/gdb.out" | head -4 | tr '\n' '|')"
    fi
    timeout 60 gdb -batch -nx -ex "set debuginfod enabled off" -ex "break p.y:5" -ex run -ex bt \
        "$TMPD/dbg" </dev/null >"$TMPD/gdb.out" 2>&1
    if grep -qE '^#0 +(0x[0-9a-f]+ in )?leaf \(\) at .*p\.y:5$' "$TMPD/gdb.out" \
        && grep -qE '^#1 .* in mid \(\) at .*p\.y:9$' "$TMPD/gdb.out"; then
        pass "gdb breaks at p.y:5, called from p.y:9"
    else
        fail "gdb breaks at p.y:5, called from p.y:9" "$(grep -E '^#|Breakpoint' "$TMPD/gdb.out" | head -4 | tr '\n' '|')"
    fi
    timeout 60 gdb -batch -nx -ex "set debuginfod enabled off" -ex "break lib.y:2" -ex run -ex bt \
        "$TMPD/m" </dev/null >"$TMPD/gdb.out" 2>&1
    if grep -qE '^#0 +(0x[0-9a-f]+ in )?twice \(\) at .*lib\.y:2$' "$TMPD/gdb.out" \
        && grep -qE '^#1 .* in _start \(\) at .*m\.y:2$' "$TMPD/gdb.out"; then
        pass "gdb breaks at lib.y:2, called from m.y:2"
    else
        fail "gdb breaks at lib.y:2, called from m.y:2" "$(grep -E '^#|Breakpoint' "$TMPD/gdb.out" | head -4 | tr '\n' '|')"
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

# 5. a program with no .bss still gets a valid symbol table and line table
printf 'exit(3);\n' >"$TMPD/q.y"
if timeout "$CTO" "$YCC" -g -o "$TMPD/q" "$TMPD/q.y" </dev/null >/dev/null 2>&1; then
    "$TMPD/q" </dev/null >/dev/null 2>&1
    ec=$?
    if [ $ec -eq 3 ] && { ! command -v readelf >/dev/null 2>&1 \
            || { readelf -a -W --debug-dump=info,abbrev,line "$TMPD/q" >/dev/null 2>"$TMPD/q.err" \
                 && [ ! -s "$TMPD/q.err" ]; }; }; then
        pass "-g on a minimal program"
    else
        fail "-g on a minimal program" "exit $ec $(head -c 200 "$TMPD/q.err" 2>/dev/null)"
    fi
else
    fail "-g on a minimal program" "ycc -g failed"
fi

# 6. -S -g: the line markers are GNU as's own .file/.loc directives
if timeout "$CTO" "$YCC" -g -S "$TMPD/p.y" </dev/null >"$TMPD/p.s" 2>"$TMPD/cc.err" \
    && grep -qxF ".file 1 \"$TMPD/p.y\"" "$TMPD/p.s" && grep -qx '\.loc 1 4' "$TMPD/p.s" \
    && timeout "$CTO" "$YCC" -S "$TMPD/p.y" </dev/null >"$TMPD/p0.s" 2>>"$TMPD/cc.err" \
    && ! grep -qE '^\.(file|loc) ' "$TMPD/p0.s"; then
    pass "-S -g carries .file/.loc, plain -S none"
else
    fail "-S -g carries .file/.loc, plain -S none" "$(head -c 300 "$TMPD/cc.err")"
fi
if command -v as >/dev/null 2>&1 && command -v readelf >/dev/null 2>&1; then
    if as -o "$TMPD/p.o" "$TMPD/p.s" 2>/dev/null \
        && readelf --debug-dump=decodedline "$TMPD/p.o" 2>/dev/null | grep -qE '^p\.y +4 '; then
        pass "GNU as reads the -S -g line markers"
    else
        fail "GNU as reads the -S -g line markers" "as or its line table failed"
    fi
else
    skip "GNU as on -S -g" "binutils not installed"
fi

# An integer literal is emitted as its value, so a -S listing says what the
# program runs: a literal wider than 64 bits (which the checker accepts, and
# which runs as its low 64 bits) used to be written out as itself, and
# `mov $18446744073709551616` is not something GNU as can read -- the listing
# did not assemble at all. Hex and binary literals keep their value through
# norm_num, including one that wraps (0xFFFFFFFFFFFFFFFF runs as -1).
if command -v as >/dev/null 2>&1; then
    printf 'print(0xff, 0b1010, 255, -7, 4294967296, 0xFFFFFFFFFFFFFFFF, 18446744073709551616, 99999999999999999999999);\n' \
        > "$TMPD/lit.y"
    if timeout "$CTO" "$YCC" -S "$TMPD/lit.y" </dev/null >"$TMPD/lit.s" 2>"$TMPD/lit.err" \
        && ! grep -qE 'mov \$[0-9]{19,}' "$TMPD/lit.s" \
        && as -o "$TMPD/lit.o" "$TMPD/lit.s" 2>"$TMPD/as.err" \
        && timeout "$CTO" "$YCC" "$TMPD/lit.y" -o "$TMPD/lit.bin" </dev/null 2>>"$TMPD/lit.err"; then
        run=$(run_bin 10 "$TMPD/lit.bin" </dev/null 2>&1)
        # 255 10 255 -7 4294967296 -1 0 200376420520689663, printed one after
        # another with no separator
        if [ "$run" = "25510255-74294967296-10200376420520689663" ]; then
            pass "-S emits a literal as its value, and GNU as assembles it"
        else
            fail "-S emits a literal as its value, and GNU as assembles it" "run '$run'"
        fi
    else
        fail "-S emits a literal as its value, and GNU as assembles it" \
            "$(head -c 200 "$TMPD/lit.err")$(head -c 200 "$TMPD/as.err")"
    fi
else
    skip "-S emits a literal as its value" "binutils not installed"
fi

print_summary "debug"
