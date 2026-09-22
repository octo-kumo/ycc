#!/bin/bash
# Native backend tests: ycc compiles test/y/native/*.y STRAIGHT TO EXECUTABLES
# (its own assembler + ELF writer — no cc/as/ld anywhere). Run, compare.
# Usage: ./test/sh/test_native.sh
# t*.y: stdout must match t*.expected, exit must match t*.exit (default 0).
# Stdin comes from t*.stdin when present, else /dev/null.
# e*.y: ycc must FAIL, and its output must contain the marker from the
#   file's `// expect-error: ...` first line.
# t10 also checks the file its program writes (see t10_filewrite.file).

source "$(dirname "$0")/lib.sh"

YCC="$ROOT/ycc"
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
        # negative test: compilation must fail with the marked message
        local want
        want=$(grep -m1 -o '// expect-error: .*' "$prog" | sed 's#// expect-error: ##')
        local err
        err=$(timeout 120 "$YCC" -o "$bin" "$prog" </dev/null 2>&1)
        local ec=$?
        rm -f "$bin"
        if [ $ec -eq 0 ]; then
            fail "$base" "compilation succeeded, expected error: $want"
        elif echo "$err" | grep -qF -- "$want"; then
            pass "$base (rejected: $want)"
        else
            fail "$base" "wrong error (want '$want', got: $(echo "$err" | head -c 200 | tr '\n' '|'))"
        fi
        return
    fi

    rm -f /tmp/ynative_test.txt
    local err
    err=$(timeout 120 "$YCC" -o "$bin" "$prog" </dev/null 2>&1)
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
    timeout 10 "$bin" <"$inf" >"$outf" 2>&1
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
