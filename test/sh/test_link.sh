#!/bin/bash
# test/sh/test_link.sh — std units and the std pack (native.y "compilation
# units", "the std pack"; ycc.y self_pack).
#
# A program is linked from units: its own and the std units it needs
# (prelude, exec, str, rt), each compiled separately. The built ycc carries
# its std units precompiled (the Makefile's PACK appends `ycc --std-pack`
# to the binary), and `--std-src` compiles them from the embedded sources
# instead. Checks: the pack is there and well framed; it is exactly what
# --std-pack writes, and what the C copy writes; linking from it gives the
# same bytes as compiling from source, plain and -g, for programs that
# pull in every unit; a pack this ycc cannot read, or none at all, falls
# back to source; a program's own y_ helper or readline replaces std's;
# --no-exec leaves exec out; std's line markers appear only under -g; and a
# compiler with no std/ beside it still resolves a library import, because every
# std source is embedded in it (fails on a build made before that).

source "$(dirname "$0")/lib.sh"

# The built ycc (override with $YSELF, e.g. ./ynew).
YCC="${YSELF:-$ROOT/ycc}"
if [ ! -x "$YCC" ]; then
    echo "error: $YCC not built — run 'make ycc' first" >&2
    exit 2
fi

TMPD="$(mktemp -d /tmp/ylink_test.XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT
CTO=$(( 120 * YTIMEOUT_SCALE ))

# A program that links every std unit: readline (prelude), exec, a
# helper-backed string method (str), and the runtime.
cat >"$TMPD/all.y" <<'EOF'
let line = readline();
let r = exec("echo hi");
let s = "a,b,c";
puts(s.upper() + "\n");
print(len(s.split(",")));
if (line == none) { puts("eof\n"); } else { puts("line\n"); };
EOF
printf 'hi\nA,B,C\n3\neof\n' >"$TMPD/all.want"

# 1. the pack: [pack][8-digit length][YCCPACK1] at the end of ycc
size=$(stat -c%s "$YCC")
plen=$(tail -c 16 "$YCC" | head -c 8)
if [ "$(tail -c 8 "$YCC")" = "YCCPACK1" ] && [[ "$plen" =~ ^[0-9]{8}$ ]] \
    && [ $((10#$plen)) -gt 0 ] && [ $((10#$plen + 16)) -lt "$size" ]; then
    pass "ycc carries a std pack ($((10#$plen)) bytes)"
    plen=$((10#$plen))
    tail -c $((plen + 16)) "$YCC" >"$TMPD/attached.pack"
    if [ "$(head -c 15 "$TMPD/attached.pack" | tr '\n' '|')" = "ycc-std-pack 6|" ]; then
        pass "the pack opens with its version line"
    else
        fail "the pack opens with its version line" "$(head -c 20 "$TMPD/attached.pack" | od -c | head -2)"
    fi
else
    fail "ycc carries a std pack" "trailer: $(tail -c 16 "$YCC" | od -c | head -1)"
    plen=0
fi

# 2. the attached pack is what --std-pack writes, and what the C copy writes
if timeout "$CTO" "$YCC" --std-pack "$TMPD/y.pack" </dev/null >"$TMPD/err" 2>&1; then
    if [ "$plen" -gt 0 ] && cmp -s "$TMPD/y.pack" "$TMPD/attached.pack"; then
        pass "--std-pack writes the attached pack"
    else
        fail "--std-pack writes the attached pack" "sizes: $(stat -c%s "$TMPD/y.pack") vs $((plen + 16))"
    fi
    if timeout "$CTO" "$CYCC" --std-pack "$TMPD/c.pack" </dev/null >"$TMPD/err" 2>&1 \
        && cmp -s "$TMPD/y.pack" "$TMPD/c.pack"; then
        pass "the C copy writes the same pack"
    else
        fail "the C copy writes the same pack" "$(head -c 200 "$TMPD/err")"
    fi
else
    fail "--std-pack writes the attached pack" "$(head -c 200 "$TMPD/err")"
fi

# 3. linking from the pack == compiling std from source, plain and -g
same_both_ways() { # same_both_ways <name> <file.y> [flags...]
    local name="$1" f="$2"
    shift 2
    if timeout "$CTO" "$YCC" "$@" -o "$TMPD/p.bin" "$f" </dev/null >"$TMPD/err" 2>&1 \
        && timeout "$CTO" "$YCC" --std-src "$@" -o "$TMPD/s.bin" "$f" </dev/null >>"$TMPD/err" 2>&1 \
        && cmp -s "$TMPD/p.bin" "$TMPD/s.bin"; then
        pass "pack == source: $name $*"
    else
        fail "pack == source: $name $*" "$(head -c 200 "$TMPD/err")"
    fi
}
for f in test/y/examples/helloworld.y test/y/native/t35_readline.y test/y/native/t38_exec.y \
         test/y/examples/ysh.y "$TMPD/all.y"; do
    case "$f" in /*) p="$f" ;; *) p="$ROOT/$f" ;; esac
    same_both_ways "$(basename "$f")" "$p"
    same_both_ways "$(basename "$f")" "$p" -g
done
if timeout "$CTO" "$YCC" -o "$TMPD/all" "$TMPD/all.y" </dev/null >"$TMPD/err" 2>&1 \
    && run_bin 10 "$TMPD/all" </dev/null >"$TMPD/all.out" 2>&1 \
    && cmp -s "$TMPD/all.out" "$TMPD/all.want"; then
    pass "a program linking all four std units runs"
else
    fail "a program linking all four std units runs" "$(head -c 200 "$TMPD/err" "$TMPD/all.out" 2>/dev/null)"
fi

# 4. a pack ycc cannot read, or none: the std units compile from source
python3 - "$YCC" "$TMPD/stale" "$TMPD/bare" <<'EOF'
import sys
d = open(sys.argv[1], "rb").read()
n = int(d[-16:-8])
i = len(d) - 16 - n
v = b"ycc-std-pack 6\n"
assert d[i:i + len(v)] == v
open(sys.argv[2], "wb").write(d[:i] + b"ycc-std-pack 0\n" + d[i + len(v):])
open(sys.argv[3], "wb").write(d[:i])
EOF
chmod 755 "$TMPD/stale" "$TMPD/bare" 2>/dev/null
for alt in stale bare; do
    if [ -x "$TMPD/$alt" ] \
        && timeout "$CTO" "$TMPD/$alt" -o "$TMPD/alt.bin" "$TMPD/all.y" </dev/null >"$TMPD/err" 2>&1 \
        && timeout "$CTO" "$YCC" -o "$TMPD/all" "$TMPD/all.y" </dev/null >>"$TMPD/err" 2>&1 \
        && cmp -s "$TMPD/alt.bin" "$TMPD/all"; then
        pass "a $alt ycc compiles std from source, same bytes"
    else
        fail "a $alt ycc compiles std from source, same bytes" "$(head -c 200 "$TMPD/err")"
    fi
done

# 5. a program's own y_ helper replaces the runtime's -- for every caller
cat >"$TMPD/ov.y" <<'EOF'
def y_print_long(n: long) -> long { puts("<" + tostring(n) + ">\n"); 0 };
print(42);
EOF
if timeout "$CTO" "$YCC" -o "$TMPD/ov" "$TMPD/ov.y" </dev/null >"$TMPD/err" 2>&1 \
    && [ "$(run_bin 10 "$TMPD/ov" </dev/null 2>&1)" = "<42>" ]; then
    pass "a program's y_print_long replaces the runtime's"
else
    fail "a program's y_print_long replaces the runtime's" "$(head -c 200 "$TMPD/err")"
fi
cat >"$TMPD/rl.y" <<'EOF'
def readline() -> str? { some("mine") };
puts(unwrap(readline()) + "\n");
EOF
if timeout "$CTO" "$YCC" -o "$TMPD/rl" "$TMPD/rl.y" </dev/null >"$TMPD/err" 2>&1 \
    && [ "$(run_bin 10 "$TMPD/rl" </dev/null 2>&1)" = "mine" ]; then
    pass "a program's readline replaces the prelude's"
else
    fail "a program's readline replaces the prelude's" "$(head -c 200 "$TMPD/err")"
fi

# 6. --no-exec: exec is not linked, so a call to it does not compile
printf 'let r = exec("echo hi");\n' >"$TMPD/ex.y"
timeout "$CTO" "$YCC" --no-exec -o "$TMPD/ex" "$TMPD/ex.y" </dev/null >"$TMPD/ex.err" 2>&1
ec=$?
if [ $ec -eq 1 ] && grep -q "undefined function 'exec'" "$TMPD/ex.err"; then
    pass "--no-exec leaves exec out"
else
    fail "--no-exec leaves exec out" "exit $ec: $(head -c 200 "$TMPD/ex.err")"
fi

# 7. std's line markers: none in plain -S, renumbered into the program's
#    .file table under -g (the program's files first, then the std units)
if timeout "$CTO" "$YCC" -S "$TMPD/all.y" </dev/null >"$TMPD/all.s" 2>"$TMPD/err" \
    && ! grep -qE '^\.(file|loc) ' "$TMPD/all.s" \
    && timeout "$CTO" "$YCC" -g -S "$TMPD/all.y" </dev/null >"$TMPD/allg.s" 2>>"$TMPD/err" \
    && [ "$(grep -E '^\.file ' "$TMPD/allg.s" | tr '\n' '|')" = ".file 1 \"$TMPD/all.y\"|.file 2 \"std/rt.y\"|.file 3 \"std/str.y\"|.file 4 \"std/exec.y\"|.file 5 \"std/prelude.y\"|" ] \
    && grep -qE '^\.loc 2 ' "$TMPD/allg.s" && grep -qE '^\.loc 5 ' "$TMPD/allg.s" \
    && ! grep -qE '^\.loc ([6-9]|[1-9][0-9])' "$TMPD/allg.s"; then
    pass "std line markers: none plain, file 2..5 under -g"
else
    fail "std line markers: none plain, file 2..5 under -g" "$(grep -E '^\.file ' "$TMPD/allg.s" 2>/dev/null | tr '\n' '|') $(head -c 200 "$TMPD/err")"
fi

# 8. A std module's own tables are built on first use, so importing it costs
# only what the program uses. crypto.y's SHA-2 round constants and its AES
# S-box were top-level `let`s: a top-level binding is inlined at _start, a
# shake root, so their immediates and (for the S-box, a str literal) their
# bytes were in every binary importing crypto.
#
# The ratchet is the *gap* between a program that never hashes and one that
# does, not a program's size against hello's: this used to compare two
# page-rounded file sizes (8,368 vs 8,368 — the padding made them equal, and
# the tables' return would have shown up as 12,464 only because it crossed a
# page). Now that a binary is its own payload, the sizes are 3,431 / 4,436 /
# 10,760 for hello+import / import+CSPRNG / import+sha256, and the guarantee
# is directly visible: a program that never hashes is 7.3 kB smaller than one
# that does, and hashing costs 6.3 kB more than the CSPRNG alone.
printf 'import crypto;\nprint("hi");\n' > "$TMPD/cryi.y"
printf 'import crypto;\nlet b = crypto.random_bytes(16);\nprint(len(b));\n' > "$TMPD/cry0.y"
printf 'print("hi");\n' > "$TMPD/hi.y"
printf 'import crypto;\ndef u(s: str) -> [byte] { crypto.unhex(s) };\nprint(crypto.hex(crypto.sha256(bytes("abc"))));\n' > "$TMPD/cry1.y"
if timeout "$CTO" "$YCC" "$TMPD/cryi.y" -o "$TMPD/cryi" </dev/null >"$TMPD/e0" 2>&1 \
    && timeout "$CTO" "$YCC" "$TMPD/cry0.y" -o "$TMPD/cry0" </dev/null >>"$TMPD/e0" 2>&1 \
    && timeout "$CTO" "$YCC" "$TMPD/hi.y" -o "$TMPD/hi" </dev/null >>"$TMPD/e0" 2>&1 \
    && timeout "$CTO" "$YCC" "$TMPD/cry1.y" -o "$TMPD/cry1" </dev/null >>"$TMPD/e0" 2>&1; then
    si=$(stat -c%s "$TMPD/cryi")
    s0=$(stat -c%s "$TMPD/cry0")
    shi=$(stat -c%s "$TMPD/hi")
    s1=$(stat -c%s "$TMPD/cry1")
    r0=$(run_bin 10 "$TMPD/cry0" </dev/null 2>&1)
    r1=$(run_bin 10 "$TMPD/cry1" </dev/null 2>&1)
    if [ "$r0" = 16 ] && [ "$r1" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ] \
        && [ "$si" -lt $((shi + 3000)) ] && [ "$s1" -gt $((si + 3000)) ] \
        && [ "$s1" -gt $((s0 + 3000)) ]; then
        pass "crypto's tables are built on first use (import only $si B, CSPRNG $s0 B, hashing $s1 B)"
    else
        fail "crypto's tables are built on first use" \
            "sizes $si/$shi/$s0/$s1, runs '$r0' '$r1'"
    fi
else
    fail "crypto's tables are built on first use" "$(head -c 200 "$TMPD/e0")"
fi

# 9. --std-pack's own errors
timeout "$CTO" "$YCC" --std-pack </dev/null >"$TMPD/e1" 2>&1
e1=$?
timeout "$CTO" "$YCC" --std-pack "$TMPD/no/such/dir/p" </dev/null >"$TMPD/e2" 2>&1
e2=$?
if [ $e1 -eq 1 ] && grep -q -- "--std-pack needs an argument" "$TMPD/e1" \
    && [ $e2 -eq 1 ] && grep -q "writing '$TMPD/no/such/dir/p' failed" "$TMPD/e2"; then
    pass "--std-pack: missing argument, unwritable path"
else
    fail "--std-pack: missing argument, unwritable path" "$e1: $(head -c 100 "$TMPD/e1") / $e2: $(head -c 100 "$TMPD/e2")"
fi

# A ycc with no std/ beside it must still compile std imports: every std source
# is embedded in the compiler (AGENTS.md, Build), and the attached pack carries
# only the four core runtime units, so a lone binary used to answer "cannot find
# module 'math'". Copy the compiler into an empty directory, run it from another
# empty one, and ask for a library module.
mkdir -p "$TMPD/lone/bin" "$TMPD/lone/run"
cp "$YCC" "$TMPD/lone/bin/ycc"
printf 'import math;\nprint(math.pi);\n' > "$TMPD/lone/run/m.y"
lone_out=$( ( cd "$TMPD/lone/run" && timeout "$CTO" "$TMPD/lone/bin/ycc" m.y -o m && \
              timeout "$CTO" ./m </dev/null ) 2>&1 )
if [ "$lone_out" = "3.141593" ]; then
    pass "lone ycc: a std import resolves with no std/ on disk"
else
    fail "lone ycc: a std import resolves with no std/ on disk" "$(echo "$lone_out" | head -c 120)"
fi

# The pack's framing must stay walkable field by field. pack_stats.py knows
# every field's shape (native.y pack_unit_fields: almost all are "count, then
# items", with only `init` a single netstring) and fails unless each unit
# consumes its fields exactly and the cursor ends at the pack's end — a desync
# is how an earlier hand parse misread the shapes. It also prints the per-field
# byte split, the measurement the pack work is planned from.
if python3 "$ROOT/test/sh/pack_stats.py" "$TMPD/y.pack" >"$TMPD/pstats" 2>&1; then
    pass "the pack parses field by field ($(grep -c '=' "$TMPD/pstats") field totals)"
else
    fail "the pack parses field by field" "$(head -c 160 "$TMPD/pstats")"
fi

print_summary "link"
