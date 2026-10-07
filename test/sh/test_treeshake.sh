#!/bin/bash
# The tree shake: what a program does not use must not be in its binary.
#
# This is the measurement behind "unused code costs nothing", and it is a
# RATCHET. It used to answer "functions yes, data no": an unused unit's
# FUNCTIONS were dropped, but its top-level globals and their initialization
# were emitted anyway, so a bare `import math;` cost 6705 bytes and ~1500
# startup instructions of `const pi = 3.14159...` and friends.
#
# That is fixed (TODO.md 9): the emitter brackets each global's initializer
# with `ygiS_<cell>` / `ygiE_<cell>` marks, the link step deletes the range of
# a cell nothing reads, and the shake after it drops what only that range
# called. math is 0 now, and so are regex, crypto, fs and struct.
#
# What is LEFT is not a blind spot, it is the purity rule doing its job: 94
# bytes for x509 and tls and 25 for json are top-level statements with an
# effect (a call, a store to another cell), which must run whether or not
# anything reads the value they produce. A range is droppable only when it
# makes no call except the allocator, writes no other cell and holds no raw
# text -- test/y/native/t348_unread_init_side_effect.y is the regression that
# rule exists for. The costs below are the recorded sizes; they may SHRINK
# freely, and a GROWTH is a regression this suite exists to catch.
set -u

source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d /tmp/ytree_XXXXXX)
trap 'rm -rf "$WORK"' EXIT

MIN="$ROOT/test/treeshake/minimal.y"
DEAD="$ROOT/test/treeshake/dead.y"

compile() {   # compile <compiler> <src> <out>
    local cc="$1" src="$2" out="$3"
    ( cd "$ROOT" && ulimit -v "${YPROG_MEM_KB:-3670016}"; \
      timeout "$((30 * ${YTIMEOUT_SCALE:-1}))" "$cc" "$src" -o "$out" ) 2>"$out.err"
}

size_of() { stat -c%s "$1" 2>/dev/null || echo 0; }

labels_of() {   # the function labels in a -S listing
    ( cd "$ROOT" && ulimit -v "${YPROG_MEM_KB:-3670016}"; \
      timeout "$((30 * ${YTIMEOUT_SCALE:-1}))" "$1" -S "$2" ) 2>/dev/null |
        grep -oE '^y_[a-zA-Z0-9_$]+:' | sort -u
}

for cc in "$CYCC" "$YREF"; do
    tag=$(basename "$cc")
    compile "$cc" "$MIN" "$WORK/min.$tag" || { fail "treeshake [$tag] minimal compiles" "$(head -2 "$WORK/min.$tag.err")"; continue; }
    BASE=$(size_of "$WORK/min.$tag")
    labels_of "$cc" "$MIN" > "$WORK/min.$tag.labels"

    # 1. An import whose functions are never called adds no FUNCTION: the
    #    kept-label set of a three-import program is the minimal program's.
    printf 'import math;\nimport regex;\nimport fs;\nprint(7);\n' > "$WORK/imports.y"
    compile "$cc" "$WORK/imports.y" "$WORK/imports.$tag" || { fail "treeshake [$tag] imports compiles"; continue; }
    labels_of "$cc" "$WORK/imports.y" > "$WORK/imports.$tag.labels"
    if diff -q "$WORK/min.$tag.labels" "$WORK/imports.$tag.labels" >/dev/null; then
        pass "treeshake [$tag] unused imports keep no function"
    else
        fail "treeshake [$tag] unused imports keep no function" \
             "$(comm -13 "$WORK/min.$tag.labels" "$WORK/imports.$tag.labels" | tr '\n' ' ')"
    fi

    # 2. The ratchet: each unit's recorded cost. Growth fails; shrinkage is
    #    reported so the numbers can be brought down deliberately.
    while read -r unit known; do
        [ -n "$unit" ] || continue
        printf 'import %s;\nprint(7);\n' "$unit" > "$WORK/one.y"
        if ! compile "$cc" "$WORK/one.y" "$WORK/one.$tag"; then
            fail "treeshake [$tag] import $unit compiles" "$(head -2 "$WORK/one.$tag.err")"
            continue
        fi
        got=$(( $(size_of "$WORK/one.$tag") - BASE ))
        if [ "$got" -gt "$known" ]; then
            fail "treeshake [$tag] unused import $unit costs $got bytes (was $known)"
        elif [ "$got" -lt "$known" ]; then
            pass "treeshake [$tag] unused import $unit costs $got bytes, DOWN from $known (update KNOWN)"
        else
            pass "treeshake [$tag] unused import $unit costs $got bytes"
        fi
    done < <(grep -v '^#' "$ROOT/test/treeshake/costs.txt")

    # 3. Reported, not gated: what the program's own dead code costs. The
    #    dead branch, its table and the helpers only it reaches are all still
    #    emitted (see dead.y's header).
    if compile "$cc" "$DEAD" "$WORK/dead.$tag"; then
        # Strip the imports: what is left is the program's OWN dead code (the
        # table, the helpers only the dead branch reaches, the branch itself,
        # the unused locals) and nothing of libc's.
        sed '/^import /d' "$DEAD" > "$WORK/dead_noimp.y"
        compile "$cc" "$WORK/dead_noimp.y" "$WORK/dead_noimp.$tag"
        printf '  [%s] dead.y %s bytes (+%s, of which %s is its OWN dead code)\n' \
               "$tag" "$(size_of "$WORK/dead.$tag")" \
               "$(( $(size_of "$WORK/dead.$tag") - BASE ))" \
               "$(( $(size_of "$WORK/dead_noimp.$tag") - BASE ))"
    else
        fail "treeshake [$tag] dead.y compiles" "$(head -2 "$WORK/dead.$tag.err")"
    fi

    # 4. Feature absence. A program that cannot need the collector must not
    #    carry it: hello.y allocates nothing, so no allocator call and no
    #    collector block may appear in its listing. This is the test the
    #    runtime's CLK_TS initializer (a `[0; 2]` global that allocated) would
    #    have failed for every binary in the tree.
    listing() {   # listing <src> [flags...]  (the shaken -S text on stdout)
        local src="$1"; shift
        ( cd "$ROOT" && ulimit -v "${YPROG_MEM_KB:-3670016}"; \
          timeout "$((30 * ${YTIMEOUT_SCALE:-1}))" "$cc" -S "$@" "$src" ) 2>/dev/null
    }
    HELLO="$ROOT/test/treeshake/hello.y"
    if listing "$HELLO" | grep -qE '(call|jmp) y_alloc|y_gc_collect:|y_gc_maybe:|collector:'; then
        fail "treeshake [$tag] hello.y carries the collector" \
             "$(listing "$HELLO" | grep -nE '(call|jmp) y_alloc|y_gc_collect:|y_gc_maybe:|collector:' | head -3 | tr '\n' ' ')"
    else
        pass "treeshake [$tag] hello.y carries no allocator and no collector"
    fi
    # print("literal") writes the bytes itself (y_print_lit), so the string
    # helpers a runtime value needs must not be linked for a literal-only
    # program -- and must still be there when the value is not a literal.
    if listing "$HELLO" | grep -qE 'y_put_hstr|y_print_hstr'; then
        fail "treeshake [$tag] hello.y links the string helpers for a literal" \
             "$(listing "$HELLO" | grep -nE 'y_put_hstr|y_print_hstr' | head -3 | tr '\n' ' ')"
    else
        pass "treeshake [$tag] hello.y prints a literal without the string helpers"
    fi
    # 4c. The inlining guards: a capturing literal and one with a nested
    #     function literal must still compute the right thing (they take the
    #     record path).
    FC="$ROOT/test/treeshake/foreach_capture.y"
    if compile "$cc" "$FC" "$WORK/fc.$tag" && ( cd "$ROOT" && "$WORK/fc.$tag" ) > "$WORK/fc.$tag.out" 2>&1 \
        && [ "$(cat "$WORK/fc.$tag.out")" = "5
6
9" ]; then
        pass "treeshake [$tag] capturing and nested literal closures still work"
    else
        fail "treeshake [$tag] capturing and nested literal closures" "$(cat "$WORK/fc.$tag.out" 2>/dev/null | tr '\n' ' ')"
    fi
    # A captured local accumulator is inlined too (the record lives on the
    # stack for the loop): no indirect call, and the size of the shape.
    FL="$ROOT/test/treeshake/foreach_local.y"
    if listing "$FL" | grep -q 'call \*%r10'; then
        fail "treeshake [$tag] foreach_local.y still calls through the record" \
             "$(listing "$FL" | grep -n 'call \*%r10' | head -2 | tr '\n' ' ')"
    else
        pass "treeshake [$tag] foreach_local.y inlines its captured literal"
    fi
    PRINTV="$ROOT/test/treeshake/print_var.y"
    if listing "$PRINTV" | grep -q 'y_print_hstr'; then
        pass "treeshake [$tag] print(variable) still links the string helper"
    else
        fail "treeshake [$tag] print(variable) lost the string helper"
    fi

    # 4b. --gc. A program that allocates once, outside any loop, must not link
    #     the collector under the default (auto); --gc=always is the escape
    #     hatch and --gc=never drops it outright. The output must not change.
    ONCE="$ROOT/test/treeshake/alloc_once.y"
    if listing "$ONCE" | grep -q 'y_gc_collect:'; then
        fail "treeshake [$tag] --gc=auto keeps the collector for a one-shot allocation"
    else
        pass "treeshake [$tag] --gc=auto omits the collector for a one-shot allocation"
    fi
    if listing "$ONCE" --gc=always | grep -q 'y_gc_collect:'; then
        pass "treeshake [$tag] --gc=always keeps the collector"
    else
        fail "treeshake [$tag] --gc=always drops the collector"
    fi
    if listing "$ROOT/test/treeshake/forloop.y" --gc=never | grep -q 'y_gc_collect:'; then
        fail "treeshake [$tag] --gc=never keeps the collector"
    else
        pass "treeshake [$tag] --gc=never drops the collector"
    fi
    if compile "$cc" "$ONCE" "$WORK/once.$tag" && ( cd "$ROOT" && "$WORK/once.$tag" ) > "$WORK/once.$tag.out" 2>&1 \
        && ( cd "$ROOT" && ulimit -v "${YPROG_MEM_KB:-3670016}"; timeout "$((30 * ${YTIMEOUT_SCALE:-1}))" "$cc" --gc=always "$ONCE" -o "$WORK/onceal.$tag" ) 2>/dev/null \
        && ( cd "$ROOT" && "$WORK/onceal.$tag" ) > "$WORK/onceal.$tag.out" 2>&1; then
        if diff -q "$WORK/once.$tag.out" "$WORK/onceal.$tag.out" >/dev/null; then
            pass "treeshake [$tag] --gc builds print the same thing"
        else
            fail "treeshake [$tag] --gc builds differ" "$(cat "$WORK/once.$tag.out")"
        fi
    else
        fail "treeshake [$tag] --gc builds run" ""
    fi

    # 5. Dead-code ratchet (test/sh/deadcode.py): the instructions a program
    #    cannot execute, which the label-level shake leaves behind. The
    #    recorded number may shrink freely; growth fails.
    while read -r name known; do
        [ -n "$name" ] || continue
        listing "$ROOT/test/treeshake/$name" > "$WORK/$name.$tag.s"
        got=$(python3 "$ROOT/test/sh/deadcode.py" "$WORK/$name.$tag.s" | sed 's/.*: \([0-9]*\) unreachable.*/\1/')
        if [ "${got:-0}" -gt "$known" ]; then
            fail "treeshake [$tag] $name has $got unreachable instructions (was $known)" \
                 "$(python3 "$ROOT/test/sh/deadcode.py" -v "$WORK/$name.$tag.s" | head -4 | tr '\n' ' ')"
        elif [ "${got:-0}" -lt "$known" ]; then
            pass "treeshake [$tag] $name $got unreachable instructions, DOWN from $known (update deadcode.txt)"
        else
            pass "treeshake [$tag] $name $got unreachable instructions"
        fi
    done < <(grep -v '^#' "$ROOT/test/treeshake/deadcode.txt")

    # 6. Size ratchet: the shapes below are the ones whose size a runtime
    #    addition moves first. Growth fails; shrinkage is reported.
    while read -r name known; do
        [ -n "$name" ] || continue
        src="$ROOT/test/treeshake/$name"
        [ -f "$src" ] || continue
        if ! compile "$cc" "$src" "$WORK/shape.$tag"; then
            fail "treeshake [$tag] $name compiles" "$(head -2 "$WORK/shape.$tag.err")"
            continue
        fi
        got=$(size_of "$WORK/shape.$tag")
        if [ "$got" -gt "$known" ]; then
            fail "treeshake [$tag] $name is $got bytes (was $known)"
        elif [ "$got" -lt "$known" ]; then
            pass "treeshake [$tag] $name $got bytes, DOWN from $known (update shapes.txt)"
        else
            pass "treeshake [$tag] $name $got bytes"
        fi
    done < <(grep -v '^#' "$ROOT/test/treeshake/shapes.txt")

    # 7. Loop parity, static half: the array methods the emitter expands
    #    inline must not cost instructions over the raw loop they replace.
    #    (bench/ measures the dynamic half under callgrind.)
    listing "$ROOT/test/treeshake/forloop.y" > "$WORK/for.$tag.s"
    listing "$ROOT/test/treeshake/foreach.y" > "$WORK/foreach.$tag.s"
    nfor=$(grep -cE '^[ \t]+[a-z]' "$WORK/for.$tag.s")
    nfe=$(grep -cE '^[ \t]+[a-z]' "$WORK/foreach.$tag.s")
    if [ "$nfe" -gt "$((nfor + 20))" ]; then
        fail "treeshake [$tag] foreach is $nfe instructions vs $nfor for the raw loop"
    else
        pass "treeshake [$tag] foreach $nfe instructions vs $nfor raw-loop"
    fi
done

print_summary treeshake
