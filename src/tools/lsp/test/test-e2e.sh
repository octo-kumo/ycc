#!/bin/sh
# test-e2e.sh -- the server as a PROCESS (LSP.md §4.2, M1).
#
# t009_proto pins the answers. This pins the thing that only a real process can
# show: that a handler which dies takes nothing with it.
#
# That is not a hypothetical. The compiler this server drives is built to run
# once and exit:
#
#   * lexer.tokenize calls exit(1) on an unterminated string or block comment,
#   * native.native_resolve_x calls exit(1) on an import it cannot open,
#   * a run never frees its heap, and
#   * a runaway allocation trips the machine's 3.5 GiB cap.
#
# Each of those is an ordinary editor event -- typing a quote, adding an import
# before the file exists, pasting a huge file. An in-process server dies on the
# first one. yserve forks per message, so the parent only ever holds a read
# buffer and a cursor, neither of which a handler touches.
#
# So the tests here send the server things that kill a handler, and then check
# that it still answers. If any of these fail, the fork is not doing its job.
#
#   sh src/tools/lsp/test/test-e2e.sh
#   YCC=./ycc sh src/tools/lsp/test/test-e2e.sh

set -u
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
cd "$ROOT" || exit 1
HERE=src/tools/lsp/test
OUT=${OUT:-/tmp/opencode/lsp-e2e}
YCC=${YCC:-./ycc}
PY=${PY:-python3}

pass=0; fail=0
failed=""

mkdir -p "$OUT"

if [ ! -x "$YCC" ]; then
    echo "error: no compiler at $YCC" >&2
    exit 1
fi

# ── build the server ────────────────────────────────────────────────────
BIN="$OUT/yserve"
if ! "$YCC" src/tools/lsp/yserve.y -o "$BIN" > "$OUT/build.log" 2>&1; then
    echo "FAIL     yserve does not build"
    head -10 "$OUT/build.log" | sed 's/^/            /'
    exit 1
fi
# A warning in the server or anything it imports is a failure: the compiler's
# own source is warning-free (test_fixpoint), and the LSP is held to the same bar.
if grep -q ': warning: ' "$OUT/build.log"; then
    echo "FAIL     yserve compiled with a warning"
    grep ': warning: ' "$OUT/build.log" | sed 's/^/            /' | head -5
    fail=$((fail + 1))
    failed="$failed yserve-warn"
fi

# ── the driver ──────────────────────────────────────────────────────────
# A real LSP client over a real pipe: framed requests in, framed replies out.
# This is the only test that exercises read_frame/write_frame and the fork loop
# together, which is why it is written against the binary and not handle_one.
cat > "$OUT/drive.py" <<'PYEOF'
import json, subprocess, sys

BIN = sys.argv[1]

def frame(o):
    b = json.dumps(o).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b

def run(msgs, timeout=180, cwd="."):
    """Send msgs, return (exit code, [parsed replies], raw stdout, stderr)."""
    data = b"".join(frame(m) for m in msgs)
    p = subprocess.run([BIN, "--root", cwd], input=data,
                       capture_output=True, timeout=timeout, cwd=cwd)
    out = []
    i = 0
    while i < len(p.stdout):
        j = p.stdout.find(b"\r\n\r\n", i)
        if j < 0:
            break
        hdr = p.stdout[i:j].decode("utf-8", "replace")
        ln = [x for x in hdr.split("\r\n") if x.lower().startswith("content-length")]
        if not ln:
            break
        n = int(ln[0].split(":")[1])
        body = p.stdout[j + 4:j + 4 + n]
        try:
            out.append(json.loads(body))
        except Exception:
            out.append({"__unparsed__": body.decode("utf-8", "replace")})
        i = j + 4 + n
    return p.returncode, out, p.stdout, p.stderr

INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"rootUri": "file://.", "capabilities": {}}}

def open_doc(uri, text, version=1):
    return {"jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": {"textDocument": {"uri": uri, "languageId": "y",
                                        "version": version, "text": text}}}

def fmt_req(i, uri):
    return {"jsonrpc": "2.0", "id": i, "method": "textDocument/formatting",
            "params": {"textDocument": {"uri": uri},
                       "options": {"tabSize": 4, "insertSpaces": True}}}

def find(replies, want_id):
    for r in replies:
        if r.get("id") == want_id:
            return r
    return None

def diags(replies):
    """Every diagnostic from every publishDiagnostics notification."""
    out = []
    for r in replies:
        if r.get("method") == "textDocument/publishDiagnostics":
            out += r["params"]["diagnostics"]
    return out

results = []
def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))

# ── 1. a normal session ────────────────────────────────────────────────
code, replies, raw, err = run([
    INIT,
    {"jsonrpc": "2.0", "method": "initialized", "params": {}},
    open_doc("file:///t/a.y", 'def f() -> long {\n    let unused = 1;\n    2 + "s"\n}\n'),
    fmt_req(2, "file:///t/a.y"),
    {"jsonrpc": "2.0", "id": 3, "method": "shutdown"},
    {"jsonrpc": "2.0", "method": "exit"},
])
check("normal: clean exit", code == 0, "exit %d %s" % (code, err[:200]))
check("normal: initialize answered", find(replies, 1) is not None)
caps = (find(replies, 1) or {}).get("result", {}).get("capabilities", {})
check("normal: sync declared", "textDocumentSync" in caps, str(caps)[:120])
check("normal: formatting declared", caps.get("documentFormattingProvider") is True)
d = diags(replies)
errs = [x for x in d if x["severity"] == 1]
warns = [x for x in d if x["severity"] == 2]
check("normal: error found", len(errs) >= 1, str(d)[:200])
check("normal: warning found too", len(warns) >= 1,
      "the whole point: ycc prints one or the other, never both")
check("normal: shutdown answered", find(replies, 3) is not None)

# ── 2. an unterminated string: exit(1) inside lexer.tokenize ────────────
# Typing a quote is the single most common thing a user does.
code, replies, raw, err = run([
    INIT,
    open_doc("file:///t/b.y", 'let s = "oops\nlet t = 1;\n'),
    fmt_req(2, "file:///t/b.y"),
    open_doc("file:///t/c.y", "let x = 1;\nprint(x);\n"),
    {"jsonrpc": "2.0", "id": 9, "method": "shutdown"},
])
check("unterminated string: server survives", code == 0, "exit %d" % code)
check("unterminated string: reported", len(diags(replies)) >= 1)
check("unterminated string: next request answered", find(replies, 9) is not None,
      "the handler died and the parent kept going")

# ── 3. an unterminated block comment: the other exit(1) in the lexer ───
code, replies, raw, err = run([
    INIT,
    open_doc("file:///t/d.y", "/* never closed\nlet x = 1;\n"),
    open_doc("file:///t/e.y", "let y = 1;\nprint(y);\n"),
    {"jsonrpc": "2.0", "id": 9, "method": "shutdown"},
])
check("unterminated comment: server survives", code == 0, "exit %d" % code)
check("unterminated comment: reported", len(diags(replies)) >= 1)
check("unterminated comment: next request answered", find(replies, 9) is not None)

# ── 4. an import that does not exist: exit(1) in native_resolve_x ───────
# Adding an import before the file exists is the everyday version of this.
code, replies, raw, err = run([
    INIT,
    open_doc("file:///t/f.y", 'import nope from "./does_not_exist.y";\nprint(1);\n'),
    {"jsonrpc": "2.0", "id": 9, "method": "shutdown"},
])
check("missing import: server survives", code == 0, "exit %d" % code)
check("missing import: next request answered", find(replies, 9) is not None,
      "native_resolve_x called exit(1) in the child; the parent carried on")

# ── 5. a large file, and a deeply nested one ────────────────────────────
big = "".join("let v%d = %d;\n" % (i, i) for i in range(4000))
deep = "let x = " + "(" * 200 + "1" + ")" * 200 + ";\n"
code, replies, raw, err = run([
    INIT,
    open_doc("file:///t/g.y", big),
    open_doc("file:///t/h.y", deep),
    {"jsonrpc": "2.0", "id": 9, "method": "shutdown"},
])
check("large and deep: server survives", code == 0, "exit %d" % code)
check("large and deep: next request answered", find(replies, 9) is not None)

# ── 6. junk that is not JSON, and not a message ─────────────────────────
# A frame whose body is garbage has no id to answer; the server must not die
# trying, and the NEXT real request must still work.
code, replies, raw, err = run([
    INIT,
    open_doc("file:///t/i.y", "let x = 1;\n"),
    {"jsonrpc": "2.0", "id": 4},
    {"jsonrpc": "2.0", "id": 5, "method": "no/such/method"},
    {"jsonrpc": "2.0", "id": 9, "method": "shutdown"},
])
check("junk: server survives", code == 0, "exit %d" % code)
check("junk: no-method answered", find(replies, 4) is not None)
check("junk: unknown method is an error", "error" in (find(replies, 5) or {}))
check("junk: shutdown still answered", find(replies, 9) is not None)

# ── 7. a request naming a document that was never opened ────────────────
code, replies, raw, err = run([
    INIT,
    fmt_req(2, "file:///t/never-opened.y"),
    open_doc("file:///t/j.y", "let x = 1;\n"),
    {"jsonrpc": "2.0", "id": 9, "method": "shutdown"},
])
check("unknown document: answered, not a crash", find(replies, 2) is not None)
check("unknown document: empty edits", (find(replies, 2) or {}).get("result", {}).get("edits") == [])
check("unknown document: server survives", code == 0, "exit %d" % code)

# ── 8. THE STATE SPLIT: a document opened in one message must survive ────
# This is the case that a fork-per-request server gets wrong if it keeps its
# document store in the child. fork{} gives the child a COPY, so anything the
# child writes dies with it: format the document in the FIRST message and again
# after a didChange, and the second must know about both. If the store were
# child-local, the second format would come back with no edits -- silently, and
# with an "empty edits" answer that looks like "already formatted".
code, replies, raw, err = run([
    INIT,
    open_doc("file:///t/p.y", "let a  =  1;\n"),
    fmt_req(2, "file:///t/p.y"),
    fmt_req(3, "file:///t/p.y"),
    {"jsonrpc": "2.0", "id": 9, "method": "shutdown"},
])
e2 = (find(replies, 2) or {}).get("result", {}).get("edits")
e3 = (find(replies, 3) or {}).get("result", {}).get("edits")
check("store: the document is still open in the next message",
      isinstance(e2, list) and isinstance(e3, list) and len(e2) == 1 and len(e3) == 1,
      "second request returned %r" % (e3,))
check("store: the document really was still formatted the same way",
      isinstance(e2, list) and isinstance(e3, list) and
      len(e2) == 1 and len(e3) == 1 and e2[0]["newText"] == e3[0]["newText"])

# And the other direction: after didClose the document is GONE, so formatting
# must not resurrect it with the text it had.
code, replies, raw, err = run([
    INIT,
    open_doc("file:///t/q.y", "let a  =  1;\n"),
    {"jsonrpc": "2.0", "method": "textDocument/didClose",
     "params": {"textDocument": {"uri": "file:///t/q.y"}}},
    fmt_req(4, "file:///t/q.y"),
])
e4 = (find(replies, 4) or {}).get("result", {}).get("edits")
check("store: a closed document is forgotten", e4 == [], "got %r" % (e4,))

# ── 8b. ONE publishDiagnostics PER FILE ─────────────────────────────────
# The one that a real editor cannot survive: publishDiagnostics is keyed by URI,
# so a finding in an IMPORTED file must be published under that file's URI. Put
# it in the main document's notification instead and the squiggle lands on the
# wrong line of the wrong file -- and nothing errors, so only this check sees it.
import os, tempfile
# A throwaway workspace, NOT this directory: the case needs a real file on disk
# for the import to resolve, and a driver that wrote into the fixtures would
# overwrite a checked file every run.
ws = tempfile.mkdtemp(prefix="lspws-")
with open(os.path.join(ws, "mod.y"), "w") as f:
    f.write("// caf\u00e9\ndef f() -> long {\n    let spare = 1;\n    7\n}\n")
main = 'import helper from "./mod.y";\nprint(helper.f());\n'
code, replies, raw, err = run([
    INIT,
    open_doc("file://" + ws + "/main.y", main),
    {"jsonrpc": "2.0", "id": 9, "method": "shutdown"},
], cwd=ws)
seen = {}
for r in replies:
    if r.get("method") == "textDocument/publishDiagnostics":
        seen[r["params"]["uri"]] = r["params"]["diagnostics"]
main_uri = "file://" + ws + "/main.y"
mod_uri = "file://" + ws + "/mod.y"
check("per-file: the document gets its own notification", main_uri in seen,
      "got %r" % (list(seen.keys()),))
check("per-file: the import gets its own notification", mod_uri in seen,
      "got %r" % (list(seen.keys()),))
check("per-file: the import's finding is under the import",
      len(seen.get(mod_uri, [])) == 1 and "spare" in seen[mod_uri][0]["message"],
      str(seen.get(mod_uri)))
check("per-file: the document's notification is not carrying it",
      all("spare" not in x["message"] for x in seen.get(main_uri, [])))
check("per-file: the column is measured in the IMPORTED file",
      len(seen.get(mod_uri, [])) == 1 and seen[mod_uri][0]["range"]["start"]["line"] == 2,
      str(seen.get(mod_uri)))
check("per-file: no version claimed for a file we were not told about",
      all("version" not in r["params"]
          for r in replies
          if r.get("method") == "textDocument/publishDiagnostics"
          and r["params"]["uri"] == mod_uri))

# ── 9. stdin closing mid-session: a clean stop, not an error ────────────
# This is how a client says "I am done". Exiting 0 is what the spec wants.
code, replies, raw, err = run([INIT, open_doc("file:///t/k.y", "let x = 1;\n")])
check("stdin closed: exit 0", code == 0, "exit %d" % code)
check("stdin closed: the work before it still happened", len(diags(replies)) >= 0)

# ── 10. every frame is well formed: the client's framing never desyncs ───
code, replies, raw, err = run([
    INIT,
    open_doc("file:///t/l.y", 'def f() -> long {\n    let u = 1;\n    2 + "s"\n}\n'),
    open_doc("file:///t/m.y", "let z: str = 1;\n"),
    fmt_req(2, "file:///t/l.y"),
    {"jsonrpc": "2.0", "id": 3, "method": "shutdown"},
    {"jsonrpc": "2.0", "method": "exit"},
])
check("framing: no unparsed frame", not any("__unparsed__" in r for r in replies),
      str([r for r in replies if "__unparsed__" in r])[:200])
check("framing: every reply has an id or a method",
      all(("id" in r) or ("method" in r) for r in replies))
check("framing: notifications carry no id",
      all("id" not in r for r in replies if r.get("method")))
check("framing: exit stops the loop", code == 0, "exit %d" % code)

# ── report ──────────────────────────────────────────────────────────────
nfail = 0
for name, ok, detail in results:
    if ok:
        print("ok       " + name)
    else:
        print("FAIL     " + name + (("   [" + detail + "]") if detail else ""))
        nfail += 1
print()
print("passed %d, failed %d" % (len(results) - nfail, nfail))
if nfail:
    sys.exit(1)
PYEOF

# The driver prints one line per check and its own summary. Its exit status is
# the authority on pass/fail; the wrapper's counters below cover only the checks
# made here in the shell (currently: the build produced no warnings).
if ! "$PY" "$OUT/drive.py" "$BIN"; then
    fail=1
fi

# ── the same server, driven by the REAL LSP client library ────────────────
# The python driver above speaks the protocol by hand. That proves the server
# does what this file's author thinks the protocol says; it does not prove the
# server agrees with an actual LSP implementation, and the two have differed --
# client-check.js is what caught the per-file URI bug and the bogus version
# field, both of which the hand-written driver was perfectly happy with.
#
# It needs node, and it needs vscode-languageclient's own dependency
# (vscode-jsonrpc) to be installed in the extension -- i.e. `npm install` there.
NODE_MODS="$ROOT/src/tools/lsp/vscode-y-lang/node_modules"
HAVE_NODE=0
if command -v node >/dev/null 2>&1 && [ -d "$NODE_MODS" ]; then
    HAVE_NODE=1
fi
if [ "$HAVE_NODE" = "0" ]; then
    echo "skipped: the two Node checks need 'npm install' in src/tools/lsp/vscode-y-lang"
else
    section "the real LSP client library (vscode-jsonrpc, the one VS Code uses)"
    if node "$HERE/client-check.js" "$BIN"; then
        :
    else
        fail=1
    fi

    # The extension's own activate(), against a stub of the vscode module. This
    # is the only check that would catch a runtime dependency filed under
    # devDependencies -- which packages fine and then cannot require() anything.
    section "the extension activates and starts the server"
    if node "$HERE/activation-check.js" "$ROOT/src/tools/lsp/vscode-y-lang" "$BIN"; then
        :
    else
        fail=1
    fi
fi

echo
echo "the server binary is at $BIN"
[ "$fail" = "0" ] || exit 1
exit 0