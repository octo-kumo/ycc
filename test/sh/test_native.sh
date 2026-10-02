#!/bin/bash
# Native backend tests: ycc compiles test/y/native/*.y STRAIGHT TO EXECUTABLES
# (its own assembler + ELF writer — no cc/as/ld anywhere). Run, compare.
# Usage: ./test/sh/test_native.sh   (YSHARD=K/N: one shard, lib.sh)
# t*.y: stdout must match t*.expected, exit must match t*.exit (default 0).
# Stdin comes from t*.stdin when present, else /dev/null. The compile's
#   warnings (lint.y) must be exactly the file's `// expect-warning: MSG`
#   markers: each draws a warning quoting MSG on the marker's own line (a
#   line drawing two carries two markers), and an unmarked warning fails.
# e*.y: ycc must FAIL, and its output must contain the text of EVERY
#   `// expect-error: ...` line in the file. One file can mark several:
#   the parser and the checker report all their errors, so a themed file
#   tests a whole family of messages (the lexer stops at its first).
#   They compile from test/y/native itself, so a message that names an
#   imported file (`m132/a.y:5`) reads the same on every machine.
# t10 also checks the file its program writes (see t10_filewrite.file).

source "$(dirname "$0")/lib.sh"

# The built ycc (override with $YCC, e.g. the ASan build for make test-asan).
YCC="${YCC:-$ROOT/ycc}"
case "$YCC" in /*) ;; *) YCC="$PWD/$YCC" ;; esac
if [ ! -x "$YCC" ]; then
    echo "error: $YCC not built — run 'make ycc' (or 'make test') first" >&2
    exit 2
fi

run_native() {
    local prog="$1"
    local base
    base=$(basename "$prog" .y)
    local dir="$ROOT/test/y/native"
    local bin
    bin=$(mktemp /tmp/ynative_bin_XXXXXX)

    if [[ "$base" == e* ]]; then
        # negative test: compilation must fail with every marked message
        local wants
        wants=$(grep -o '// expect-error: .*' "$prog" | sed 's#// expect-error: ##')
        rm -f "$bin"
        if [ -z "$wants" ]; then
            fail "$base" "no // expect-error: marker"
            return
        fi
        local first nwant
        first=$(echo "$wants" | head -1)
        nwant=$(echo "$wants" | wc -l)
        local err
        err=$(cd "$dir" && timeout $(( 120 * YTIMEOUT_SCALE )) "$YCC" -o "$bin" "$base.y" </dev/null 2>&1)
        local ec=$?
        rm -f "$bin"
        if [ $ec -eq 0 ]; then
            fail "$base" "compilation succeeded, expected error: $first"
            return
        fi
        local want
        while IFS= read -r want; do
            if ! echo "$err" | grep -qF -- "$want"; then
                fail "$base" "wrong error (want '$want', got: $(echo "$err" | head -c 400 | tr '\n' '|'))"
                return
            fi
        done <<< "$wants"
        if [ "$nwant" -gt 1 ]; then
            pass "$base (rejected: $first, +$((nwant - 1)) more)"
        else
            pass "$base (rejected: $first)"
        fi
        return
    fi

    # the one fixed path a fixture writes; only t10 may touch it, so a
    # shard running beside this one never removes it mid-check
    [ "$base" = "t10_filewrite" ] && rm -f /tmp/ynative_test.txt
    local err
    err=$(timeout $(( 120 * YTIMEOUT_SCALE )) "$YCC" -o "$bin" "$prog" </dev/null 2>&1)
    if [ $? -ne 0 ]; then
        fail "$base" "compile failed: $(echo "$err" | head -c 200 | tr '\n' '|')"
        rm -f "$bin"
        return
    fi
    if [ ! -x "$bin" ]; then
        fail "$base" "output is not executable"
        rm -f "$bin"
        return
    fi
    # the warnings: "LINE:COL: warning: MSG" (the fixture is the main file,
    # so its positions are bare), against the markers as "LINE:MSG"
    local warns marks m wl
    warns=$(echo "$err" | grep -F ': warning: ')
    marks=$(awk -v M="// expect-warning: " '{
        s = $0
        while ((i = index(s, M)) > 0) {
            s = substr(s, i + length(M)); j = index(s, " " M)
            print NR ":" (j ? substr(s, 1, j - 1) : s)
            if (!j) break
            s = substr(s, j + 1)
        }
    }' "$prog")
    while IFS= read -r m; do
        [ -z "$m" ] && continue
        wl=${m%%:*}
        if ! echo "$warns" | grep -F -- "${m#*:}" | grep -q "^$wl:"; then
            fail "$base" "no warning '${m#*:}' on line $wl (got: $(echo "$warns" | head -c 300 | tr '\n' '|'))"
            rm -f "$bin"
            return
        fi
    done <<< "$marks"
    if [ "$(echo "$warns" | grep -c .)" -ne "$(echo "$marks" | grep -c .)" ]; then
        fail "$base" "unmarked warnings (got: $(echo "$warns" | head -c 300 | tr '\n' '|'))"
        rm -f "$bin"
        return
    fi
    local outf
    outf=$(mktemp /tmp/ynative_out_XXXXXX)
    # stdin comes from <base>.stdin when present (t12 cat test), else /dev/null
    local inf="/dev/null"
    [ -f "$dir/$base.stdin" ] && inf="$dir/$base.stdin"
    run_bin 10 "$bin" <"$inf" >"$outf" 2>&1
    local ec=$?
    local want_ec=0
    [ -f "$dir/$base.exit" ] && want_ec=$(cat "$dir/$base.exit")
    local ok=1
    [ "$ec" != "$want_ec" ] && ok=0
    # exact byte comparison (trailing newlines are significant: print("")
    # outputs a lone newline, so never use $(...) capture here).
    if ! diff -u "$dir/$base.expected" "$outf" > "$outf.diff" 2>&1; then
        ok=0
    fi
    # t10 writes a file; check its contents too
    if [ "$base" = "t10_filewrite" ]; then
        if ! diff -u "$dir/$base.file" /tmp/ynative_test.txt >/dev/null 2>&1; then
            fail "$base" "output file mismatch (want '$(cat "$dir/$base.file" | tr '\n' '|')', got '$(cat /tmp/ynative_test.txt 2>/dev/null | tr '\n' '|')')"
            rm -f "$bin" "$outf" "$outf.diff"
            return
        fi
    fi
    if [ $ok -eq 1 ]; then
        pass "$base"
    else
        fail "$base" "exit=$ec (want $want_ec), diff: $(head -c 200 "$outf.diff" | tr '\n' '|')"
    fi
    rm -f "$bin" "$outf" "$outf.diff"
}

echo "═══════════════════════════════════════════"
echo "  y native backend (real assembly)"
echo "═══════════════════════════════════════════"
echo ""

for f in "$ROOT"/test/y/native/t*.y "$ROOT"/test/y/native/e*.y; do
    next_case && run_native "$f"
done

print_summary "native"
