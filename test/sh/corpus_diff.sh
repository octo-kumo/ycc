#!/bin/bash
# corpus_diff.sh — what a compiler change changes. Every program is
# compiled by BASE and by NEW; each one whose exit code, messages or binary
# differ is listed, and each binary that differs is run under both builds
# (stdin from the .stdin file beside the program, else /dev/null) to tell
# a change of code from a change of behavior (stdout+stderr, exit code).
# A program whose output is not deterministic (clocks, pids) reads as a
# behavior change.
# Not a suite: differences are the point. Exit 0 iff every program
# compiles and behaves the same under both builds (its code may differ).
# Usage: test/sh/corpus_diff.sh BASE NEW [FILE...]     (make corpus-diff)
# Default FILEs: every test/y/**/*.y, then src/y/ycc.y. YJOBS programs at a
# time (default: the number of CPUs).

source "$(dirname "$0")/lib.sh"

if [ $# -lt 2 ]; then
    echo "usage: test/sh/corpus_diff.sh BASE NEW [FILE...]" >&2
    exit 2
fi
BASE="$(readlink -f "$1")"
NEW="$(readlink -f "$2")"
shift 2
[ -x "$BASE" ] || { echo "corpus_diff: $BASE is not an executable" >&2; exit 2; }
[ -x "$NEW" ] || { echo "corpus_diff: $NEW is not an executable" >&2; exit 2; }
if [ $# -gt 0 ]; then
    FILES=()
    for a in "$@"; do FILES+=("$(readlink -f "$a")"); done
else
    mapfile -t FILES < <(find "$ROOT/test/y" -name '*.y' | sort)
    FILES+=("$ROOT/src/y/ycc.y")
fi
JOBS="${YJOBS:-$(nproc)}"
cd "$ROOT" || exit 2   # where imports of std modules resolve (src/y/std/)

TMP="$(mktemp -d -t ycorpus.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# diff_one <i> <file>: the report on one program goes to $TMP/<i>.out, its
# verdict to $TMP/<i>.kind: "code" if its binary differs, "behavior" if it
# compiles or runs differently (both words when both hold).
diff_one() {
    local i=$1 f name d kind=""
    f="$(readlink -f "$2")"
    name="${f#"$ROOT"/}"
    d="$TMP/$i"
    mkdir "$d"
    # the compiler's own source is the heaviest input by far
    local to=60
    [ "$name" = src/y/ycc.y ] && to=300
    local eb en rb rn
    eb=$(timeout "$to" "$BASE" -o "$d/base" "$f" </dev/null 2>&1)
    rb=$?
    en=$(timeout "$to" "$NEW" -o "$d/new" "$f" </dev/null 2>&1)
    rn=$?
    {
        if [ $rb -ne $rn ] || [ "$eb" != "$en" ]; then
            echo "DIFF compile   $name (exit $rb -> $rn)"
            diff <(printf '%s\n' "$eb") <(printf '%s\n' "$en") | grep '^[<>]' | head -6 | sed 's/^/    /'
            kind=behavior
        elif [ $rb -eq 0 ] && ! cmp -s "$d/base" "$d/new"; then
            kind=code
            if [ "$name" = src/y/ycc.y ]; then
                echo "DIFF code      $name (the compiler's own code)"
            else
                local in=/dev/null
                [ -f "${f%.y}.stdin" ] && in="${f%.y}.stdin"
                # run where a file the program writes cannot land in the repository
                (cd "$d" && run_bin 10 ./base <"$in" >out.base 2>&1; echo "exit $?" >>out.base)
                (cd "$d" && run_bin 10 ./new <"$in" >out.new 2>&1; echo "exit $?" >>out.new)
                if cmp -s "$d/out.base" "$d/out.new"; then
                    echo "DIFF code      $name (same behavior)"
                else
                    echo "DIFF behavior  $name"
                    diff -a "$d/out.base" "$d/out.new" | grep -a '^[<>]' | head -8 | sed 's/^/    /'
                    kind="code behavior"
                fi
            fi
        fi
    } >"$TMP/$i.out"
    echo "$kind" >"$TMP/$i.kind"
    rm -rf "$d"
}

# the last program first: by default it is the compiler, the longest
n=${#FILES[@]}
running=0
for i in $((n - 1)) $(seq 0 $((n - 2))); do
    if [ $running -ge "$JOBS" ]; then
        wait -n
        running=$((running - 1))
    fi
    diff_one "$i" "${FILES[$i]}" &
    running=$((running + 1))
done
wait

code=0
behavior=0
for ((i = 0; i < n; i++)); do
    cat "$TMP/$i.out"
    case " $(cat "$TMP/$i.kind") " in *" code "*) code=$((code + 1)) ;; esac
    case " $(cat "$TMP/$i.kind") " in *" behavior "*) behavior=$((behavior + 1)) ;; esac
done
echo "$n programs: $code compile to different code, $behavior compile or behave differently"
[ $behavior -eq 0 ]
