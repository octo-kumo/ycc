#!/bin/bash
# Coverage: makes "every feature has a test" a checkable claim.
# Usage: ./test/sh/test_coverage.sh [-v]
# Static — reads the sources, the reference manual and the tests; compiles
# nothing. Four checks, each a list of things that must have a test:
#
#  1. diagnostics: every message a diagnostic site in the compiler can print
#     (lexer, parser, renamer, checker, imports/embeds, driver, runtime
#     traps, lint warnings) has its text in a test expectation — an e*.y
#     `// expect-error:` or t*.y `// expect-warning:` marker, an inline
#     case in test/sh/*.sh, or a *.expected file. A site's
#     message is a template: its constant text, with holes where names and
#     types go. One expectation line matching the whole template covers
#     every site that builds that message. Sites with no constant text, and
#     messages no test can reach, are listed with a reason in COVERAGE.md.
#  2. builtins: every builtin and string method in docs/src/09-builtins.tex
#     is called by a test whose output is checked (test/y/native/t*.y, or an
#     inline case in test/sh/*.sh).
#  3. keywords: every keyword the lexer knows appears in a t*.y program.
#  4. matrix: test/COVERAGE.md has a row for every (sub)section of the
#     reference manual (docs/src/[0-9]*.tex), and every test a row names
#     exists and checks its output.
# -v lists what each check found, not just what is missing.

source "$(dirname "$0")/lib.sh"

VERBOSE=0
[ "$1" = "-v" ] && VERBOSE=1
MATRIX="$ROOT/test/COVERAGE.md"
SRC="$ROOT/src/y"
TMP=$(mktemp -d /tmp/ycov_XXXXXX)
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$MATRIX" ]; then
    fail "coverage" "missing $MATRIX"
    print_summary "coverage"
    exit 1
fi

# Rows of the COVERAGE.md table under heading "## $1": the cells of each
# `| a | b | ... |` line, tab-separated, header and rule rows dropped.
matrix_rows() {
    awk -v want="## $1" '
        /^## / { on = ($0 == want); next }
        on && /^\|/ {
            if ($0 ~ /^\|[-| ]*$/) next          # the |---|---| rule
            n = split($0, c, "|"); row = ""
            for (i = 2; i < n; i++) {
                gsub(/^[ \t]+|[ \t]+$/, "", c[i])
                row = row (i > 2 ? "\t" : "") c[i]
            }
            if (!hdr++) next                     # the header row
            print row
        }' "$MATRIX"
}

# ---------------------------------------------------------------- 1. diagnostics
# The sites, their message templates and the matching: coverage_diag.awk.
{
    grep -h -o '// expect-error: .*' "$ROOT"/test/y/native/e*.y | sed 's#// expect-error: ##'
    grep -h -o '// expect-warning: .*' "$ROOT"/test/y/native/t*.y | sed 's#// expect-warning: ##'
    for s in "$ROOT"/test/sh/*.sh; do
        [ "$(basename "$s")" = test_coverage.sh ] || cat "$s"
    done
    find "$ROOT/test/y" -name '*.expected' -exec cat {} +
} > "$TMP/expect"
matrix_rows "Untested diagnostics" | awk -F'\t' '{ gsub(/`/, "", $1); gsub(/`/, "", $2); sub(/^src\/y\//, "", $1); print $1 "\t" $2 }' > "$TMP/excused"
awk -v EXCF="$TMP/excused" -v EXPF="$TMP/expect" -f "$ROOT/test/sh/coverage_diag.awk" \
    "$TMP/excused" "$TMP/expect" \
    "$SRC/lexer.y" "$SRC/parser.y" "$SRC/rename.y" "$SRC/types.y" "$SRC/native.y" \
    "$SRC/ycc.y" "$SRC/pkg.y" "$SRC/lint.y" "$SRC/arch_x64.y" "$SRC"/std/*.y > "$TMP/sites"
nsites=$(grep -c -v '^stale' "$TMP/sites")
nmiss=0
while IFS=$'\t' read -r status loc what; do
    case "$status" in
        tested | excused) [ $VERBOSE -eq 1 ] && echo "  $status  $loc  $what" ;;
        untested)
            nmiss=$((nmiss + 1))
            fail "diagnostic $loc untested" "$what" ;;
        dynamic)
            nmiss=$((nmiss + 1))
            fail "diagnostic $loc has no constant text (excuse it in COVERAGE.md by a fragment of its code)" "$what" ;;
        stale)
            nmiss=$((nmiss + 1))
            fail "COVERAGE.md excuses '$what' in $loc, but no untested site has it" ;;
    esac
done < "$TMP/sites"
[ $nmiss -eq 0 ] && pass "diagnostics: all $nsites sites tested or excused"

# ---------------------------------------------------------------- 2. builtins
# The description lists of 09-builtins.tex: function builtins are written
# \ic{name(...)}, methods \ic{s.name(...)}.
awk '/\\begin\{description\}/ { on = 1 } on { print } /\\end\{description\}/ { on = 0 }' \
    "$ROOT/docs/src/09-builtins.tex" | grep -o '\\ic{[a-z]*\.\?[a-z\\_]*(' |
    sed 's/^\\ic{//; s/($//; s/\\_/_/g; s/^[a-z]*\././' | sort -u > "$TMP/builtins"
{
    cat "$ROOT"/test/y/native/t*.y
    # the ulp harness's calls: it is what calls std/math.y's float layer, and it
    # lives outside test/y/native (it reads a table, so it is not a fixture)
    cat "$ROOT"/test/math/*.y
    for s in "$ROOT"/test/sh/test_*.sh; do
        [ "$(basename "$s")" = test_coverage.sh ] || cat "$s"
    done
} > "$TMP/runs"
nb=0; nmiss=0
while read -r b; do
    nb=$((nb + 1))
    if [[ "$b" == .* ]]; then
        pat="\\${b}\\("
    else
        pat="(^|[^A-Za-z0-9_.])${b}\\("
    fi
    if grep -qE -- "$pat" "$TMP/runs"; then
        [ $VERBOSE -eq 1 ] && echo "  called   $b"
    else
        nmiss=$((nmiss + 1))
        fail "builtin $b is never called by a checked test"
    fi
done < "$TMP/builtins"
[ $nmiss -eq 0 ] && pass "builtins: all $nb documented builtins and methods called"

# ---------------------------------------------------------------- 3. keywords
# The lexer's keywords: its `word == "..." ) { ty = "kw"` chain. (The
# contextual words — match, type, self, none, import, embed — are grammar,
# covered by the matrix rows.)
grep -o 'word == "[a-z_]*") { ty = "kw"' "$SRC/lexer.y" |
    sed 's/word == "//; s/").*//' | sort -u > "$TMP/keywords"
if [ ! -s "$TMP/keywords" ]; then
    fail "keywords" "found no keyword chain in src/y/lexer.y"
fi
nk=0; nmiss=0
while read -r kw; do
    nk=$((nk + 1))
    if cat "$ROOT"/test/y/native/t*.y | grep -qw -- "$kw"; then
        [ $VERBOSE -eq 1 ] && echo "  used     $kw"
    else
        nmiss=$((nmiss + 1))
        fail "keyword '$kw' appears in no t*.y program"
    fi
done < "$TMP/keywords"
[ $nmiss -eq 0 ] && [ $nk -gt 0 ] && pass "keywords: all $nk used"

# ---------------------------------------------------------------- 4. matrix
# Every \section/\subsection title of docs/src/NN-*.tex, as "NN-name<TAB>title".
for t in "$ROOT"/docs/src/[0-9]*.tex; do
    awk -v f="$(basename "$t" .tex)" '
        /^\\(sub)?section\*?\{/ {
            s = $0; sub(/^\\(sub)?section\*?\{/, "", s); sub(/\}[^}]*$/, "", s)
            gsub(/\\ic\{|\}/, "", s); gsub(/\\/, "", s)
            print f "\t" s
        }' "$t"
done > "$TMP/sections"
matrix_rows "Features" > "$TMP/rows"
nsec=0; nmiss=0
while IFS=$'\t' read -r doc title; do
    nsec=$((nsec + 1))
    if ! awk -F'\t' -v d="$doc" -v t="$title" '$1 == d && $2 == t { found = 1 } END { exit !found }' "$TMP/rows"; then
        nmiss=$((nmiss + 1))
        fail "manual section $doc '$title' has no row in test/COVERAGE.md"
    fi
done < "$TMP/sections"
[ $nmiss -eq 0 ] && pass "matrix: all $nsec manual sections have rows"

# Every test a row names must exist and check its output: a native fixture
# (native/t01_x.y with its .expected, or an e*.y with its markers), a
# test/sh suite (sh/test_x.sh), or an inline case of test_comprehensive.sh
# or test_loops.sh (comprehensive: NAME, loops: NAME — the case whose name
# starts with NAME). audit/ and examples/ programs only check that the two
# compilers agree, so they are no evidence that a feature works.
nref=0; nmiss=0
while IFS=$'\t' read -r doc title feature tests; do
    if [ -z "$tests" ]; then
        nmiss=$((nmiss + 1))
        fail "matrix row $doc '$title' / '$feature' names no test"
        continue
    fi
    # a section with nothing to run (the manual's notation, say) says why
    if [[ "$tests" =~ ^none:\ .{10,} ]]; then
        [ $VERBOSE -eq 1 ] && echo "  untestable  $doc '$title': $tests"
        continue
    fi
    while read -r ref; do
        [ -z "$ref" ] && continue
        nref=$((nref + 1))
        ok=0
        case "$ref" in
            comprehensive:* | loops:*)
                suite="$ROOT/test/sh/test_${ref%%:*}.sh"; name="${ref#*: }"
                for h in run_test silent_test inline_test; do
                    grep -qF -- "$h \"$name" "$suite" && ok=1
                done ;;
            sh/test_*.sh) [ -f "$ROOT/test/$ref" ] && ok=1 ;;
            native/t*.y) [ -f "$ROOT/test/y/$ref" ] && [ -f "$ROOT/test/y/${ref%.y}.expected" ] && ok=1 ;;
            native/e*.y) [ -f "$ROOT/test/y/$ref" ] && ok=1 ;;
        esac
        if [ $ok -eq 0 ]; then
            nmiss=$((nmiss + 1))
            fail "matrix row $doc '$title' / '$feature': '$ref' is not a checked test"
        fi
    done < <(echo "$tests" | grep -o '`[^`]*`' | tr -d '`')
done < "$TMP/rows"
[ $nmiss -eq 0 ] && pass "matrix: all $nref test references exist"

print_summary "coverage"
