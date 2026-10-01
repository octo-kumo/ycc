#!/bin/bash
# Native backend tests: ycc compiles test/y/native/*.y STRAIGHT TO EXECUTABLES
# (its own assembler + ELF writer — no cc/as/ld anywhere). Run, compare.
# Usage: ./test/sh/test_native.sh
# t*.y: stdout must match t*.expected, exit must match t*.exit (default 0).
# Stdin comes from t*.stdin when present, else /dev/null.
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

    rm -f /tmp/ynative_test.txt
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
    if ! diff -u "$dir/$base.expected" "$outf" > /tmp/yn_diff.txt 2>&1; then
        ok=0
    fi
    # t10 writes a file; check its contents too
    if [ "$base" = "t10_filewrite" ]; then
        if ! diff -u "$dir/$base.file" /tmp/ynative_test.txt >/dev/null 2>&1; then
            fail "$base" "output file mismatch (want '$(cat "$dir/$base.file" | tr '\n' '|')', got '$(cat /tmp/ynative_test.txt 2>/dev/null | tr '\n' '|')')"
            rm -f "$bin" "$outf"
            return
        fi
    fi
    if [ $ok -eq 1 ]; then
        pass "$base"
    else
        fail "$base" "exit=$ec (want $want_ec), diff: $(head -c 200 /tmp/yn_diff.txt | tr '\n' '|')"
    fi
    rm -f "$bin" "$outf"
}

echo "═══════════════════════════════════════════"
echo "  y native backend (real assembly)"
echo "═══════════════════════════════════════════"
echo ""

for f in "$ROOT"/test/y/native/t*.y "$ROOT"/test/y/native/e*.y; do
    run_native "$f"
done

print_summary "native"
