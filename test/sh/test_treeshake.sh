#!/bin/bash
# The tree shake: what a program does not use must not be in its binary.
#
# This is the measurement behind "unused code costs nothing", and it is a
# RATCHET because the answer today is "functions yes, data no": every unused
# std unit's FUNCTIONS are dropped (the kept labels of a program importing
# math, regex and fs are the labels of one importing nothing), but a unit's
# top-level GLOBALS and their initialization are emitted anyway. `import math;`
# costs a program that never calls it 6705 bytes and ~1500 startup
# instructions, all of it `const pi = 3.14159...` and friends. The costs below
# are the recorded sizes; they may SHRINK freely (that is the work: shaking
# globals, and folding the constants they hold into their uses), and a GROWTH
# is a regression this suite exists to catch.
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
done

print_summary treeshake
