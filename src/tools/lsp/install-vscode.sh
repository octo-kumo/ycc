#!/bin/bash
# install-vscode.sh — build yserve and the extension, then install both into VS Code.
#
#   sh src/tools/lsp/install-vscode.sh [--dry-run]
#
# The two halves are separate products with one build path each, so the script
# only orders them; every build step is the Makefile's own target, because
# duplicating a build here is how a second copy drifts from the first.
#
#   make yserve    -> ./yserve at the repository root, the language server.
#                     `make lsp-vsix` deliberately does NOT build it: the
#                     extension finds the server at runtime, so shipping one
#                     inside the .vsix would bake in the machine that built it.
#   make lsp-vsix  -> src/tools/lsp/vscode-y-lang/y-lang-<version>.vsix, which
#                     is `make lsp-ext` (npm install + tsc) plus `vsce package`.
#
# Which is why the last real step is a COPY. The extension looks for the server in
# this order (src/tools/lsp/vscode-y-lang/src/client.ts, `candidates`):
#
#   1. y.lsp.serverPath, if set -- used ALONE, with no fallback
#   2. next to the extension, then one and two directories up
#   3. the workspace root, and yserve/ under it
#
# An installed extension lives in ~/.vscode/extensions/yun.y-lang-<version>/, so
# (2) is ~/.vscode itself and (3) is whichever project you happen to have open.
# Neither reaches the repository. Working INSIDE this repository, (3) finds
# ./yserve and no copy is needed; from anywhere else the copy is what makes the
# install work with nothing left to configure.
#
# Two honest caveats, printed at the end rather than left to be discovered:
#
#   * An extension UPDATE replaces that directory, and the copy with it. So after
#     an update, either run this again or set `y.lsp.serverPath`, which survives
#     one and is what the extension's own error message tells you to do.
#   * A rebuild of ./yserve does NOT reach the copy. Re-run this, or set
#     `y.lsp.serverPath` and skip step 4 entirely.
#
# Do NOT run this under an address-space cap. `make`'s own recipes set one for
# every compile they start (AGENTS.md), so nothing here needs it, and the `code`
# CLI is Electron, which reserves far more *virtual* address space than it uses
# and dies under `ulimit -v` with a Trace/breakpoint trap -- which reads as "the
# install failed" rather than as the cap. `test/sh/capped.sh` is for the suites;
# this is not one of them.

set -u

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
run()  {
    if [ "$DRY" -eq 1 ]; then
        printf '   would run: %s\n' "$*"
    else
        printf '   $ %s\n' "$*"
        "$@" || return 1
    fi
    return 0
}

# A path's parent, from the shell alone. `dirname` is an external command, and
# depending on it here made this script exit 0 -- reporting success -- on a PATH
# too thin to have one. Parameter expansion needs nothing but the shell.
parent() { case "$1" in */*) printf '%s\n' "${1%/*}" ;; *) printf '%s\n' "." ;; esac; }

# The repository root, found by walking up to the Makefile rather than by counting
# `..`: a fixed count is wrong the moment this file moves, and it fails by building
# in the wrong directory rather than by stopping. Two files are required, so a
# stray Makefile in a parent does not count.
ROOT=""
d=$(cd "$(dirname "$0" 2>/dev/null || printf '.')" && pwd) || d=""
for _ in 1 2 3 4 5 6; do
    [ -n "$d" ] || break
    if [ -f "$d/Makefile" ] && [ -f "$d/src/y/ycc.y" ]; then ROOT="$d"; break; fi
    [ "$d" = "/" ] && break
    d=$(parent "$d")
done
[ -n "$ROOT" ] || { say "install-vscode: no Makefile and src/y/ycc.y above this script"; exit 1; }
EXT="$ROOT/src/tools/lsp/vscode-y-lang"
DRY=0
FORCE=0

usage() {
    cat <<'EOF'
usage: sh src/tools/lsp/install-vscode.sh [--dry-run] [--force]

  --dry-run   print the steps and the commands, build and install nothing.
  --force     install even while VS Code is running. Not advised: it replaces
             the live extension's files, which has frozen VS Code here.

Builds yserve and the VS Code extension through the Makefile, installs the .vsix
with the `code` CLI, and copies yserve next to the installed extension so the
server is found without configuring anything.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --force) FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) say "install-vscode: unknown argument '$1'"; usage; exit 2 ;;
    esac
    shift
done

[ -d "$EXT" ] || { say "install-vscode: $EXT is missing -- run this from the repository"; exit 1; }

# ── what has to be on PATH ────────────────────────────────────────────────
#
# npm builds the extension and `vsce` packages it, so node and npm are hard
# requirements. The `code` CLI is NOT: VS Code installs it from the Command
# Palette ("Shell Command: Install 'code' command in PATH") and on many machines
# it is simply absent, in which case the manual step at the end does the same
# thing. Failing there would make this script useless on exactly the setups that
# need it most, so it is a warning and not an error.
MISSING=""
for tool in node npm; do
    command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
    say "install-vscode: missing$MISSING -- both build the extension (npm ci && tsc)."
    say "  node: https://nodejs.org/   (VS Code's own build of Electron ships one;"
    say "         a PATH node is only needed for the extension's compile step)"
    exit 1
fi

CODE=""
for c in code code-insiders codium; do
    if command -v "$c" >/dev/null 2>&1; then CODE="$c"; break; fi
done
if [ -z "$CODE" ]; then
    say "install-vscode: no 'code' CLI on PATH, so the .vsix will not be installed"
    say "  for you. Everything is still built; finish with either"
    say "    Extensions: Install from VSIX...  in the Command Palette, or"
    say "    <path-to>/bin/code --install-extension '$EXT/<vsix>' --force"
    say "  after adding the 'code' command to PATH from the Command Palette"
    say "  (\"Shell Command: Install 'code' command in PATH\")."
fi

VSIX=$(cd "$EXT" && node -p "require('./package.json').name + '-' + require('./package.json').version + '.vsix'") || exit 1

TARGET=$CODE
[ -n "$TARGET" ] || TARGET="VS Code, by hand"
say "install-vscode: $VSIX, into $TARGET"

# ── 1. the server ─────────────────────────────────────────────────────────
step "1/4  the language server"
run make -C "$ROOT" yserve || { say "install-vscode: 'make yserve' failed"; exit 1; }
[ "$DRY" -eq 1 ] || [ -x "$ROOT/yserve" ] || { say "install-vscode: ./yserve is missing after the build"; exit 1; }

# ── 2. the extension ──────────────────────────────────────────────────────
step "2/4  the extension (npm install, tsc, vsce package)"
run make -C "$ROOT" lsp-vsix || { say "install-vscode: 'make lsp-vsix' failed"; exit 1; }
VSIX_PATH="$EXT/$VSIX"
[ "$DRY" -eq 1 ] || [ -f "$VSIX_PATH" ] || { say "install-vscode: $VSIX_PATH is missing after the build"; exit 1; }

# ── 3. install it ─────────────────────────────────────────────────────────
#
# --force because an install of the same id and version is otherwise refused,
# and re-running this after a rebuild is the normal case rather than the odd one.
#
# REFUSED WHILE VS CODE IS RUNNING, unless --force. Installing the same version
# over a live extension REPLACES its directory underneath the running extension
# host. The host does not always survive that: the reported symptom was VS Code
# itself frozen for a minute, with no Y file open, and the server measured 35 ms
# per request on the largest file in the repository -- so the extension host being
# left pointing at files that were deleted and recreated is the only thing that
# fits. Closing VS Code first costs nothing and removes the whole class.
step "3/4  install the extension"
if [ "$FORCE" -eq 0 ] && [ "$DRY" -eq 0 ] && [ -n "$CODE" ]; then
    if pgrep -f "resources/app/out/vs/code" >/dev/null 2>&1 \
       || pgrep -x code >/dev/null 2>&1 \
       || pgrep -x code-insiders >/dev/null 2>&1; then
        say "install-vscode: VS Code is running."
        say "  Installing over a live extension replaces its files underneath the"
        say "  extension host, and that has frozen VS Code here. Quit VS Code and"
        say "  run this again, or pass --force if you know the reload will be clean."
        exit 1
    fi
fi
if [ -n "$CODE" ]; then
    run "$CODE" --install-extension "$VSIX_PATH" --force || {
        say "install-vscode: the install failed. Install it by hand:"
        say "  $CODE --install-extension '$VSIX_PATH' --force"
        say "  or: Extensions: Install from VSIX... in the Command Palette"
        exit 1
    }
else
    # Nothing to run, and NOT a failure: the .vsix is built either way and the
    # manual route at the end is the same install. Printing `true` here would be
    # technically honest and useless to read.
    say "   skipped -- install it by hand as described above"
fi

# ── 4. the server, where the extension will look for it ───────────────────
#
# `<extensionDir>/yserve`, the first candidate the extension tries after
# y.lsp.serverPath, and a plain executable file -- which is what client.ts's
# isExecutableFile requires (stat says a file, access says X_OK). `install -m`
# rather than `cp` because it sets the mode in the same step, and because a
# dangling symlink here would surface as an extension that "cannot find yserve"
# with a path that looks right.
step "4/4  put yserve next to the installed extension"
ID=$(cd "$EXT" && node -p "require('./package.json').publisher + '.' + require('./package.json').name") || exit 1
DEST=""
for root in "${VSCODE_EXTENSIONS:-}" "$HOME/.vscode/extensions" "$HOME/.vscode-insiders/extensions"; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    # Newest first: after an update the old version's directory is still there,
    # and the copy must land in the one VS Code is actually running.
    found=$(ls -dt "$root/$ID"-* 2>/dev/null | head -1)
    [ -n "$found" ] && [ -d "$found" ] && { DEST="$found"; break; }
done

if [ -z "$DEST" ]; then
    say "   could not find the installed extension directory for '$ID'."
    say "   Set y.lsp.serverPath to $ROOT/yserve instead -- it survives an"
    say "   extension update, and this copy would not:"
    say "     \"y.lsp.serverPath\": \"$ROOT/yserve\""
elif [ "$DRY" -eq 1 ]; then
    printf '   would run: install -m 755 %s %s\n' "$ROOT/yserve" "$DEST/yserve"
else
    run install -m 755 "$ROOT/yserve" "$DEST/yserve" || {
        say "install-vscode: could not write into $DEST"
        say "   Set y.lsp.serverPath to $ROOT/yserve instead."
    }
fi

# ── done ──────────────────────────────────────────────────────────────────
cat <<EOF

Next:
  * Reload the window: Developer: Reload Window (or restart VS Code). The
    extension activates on a .y file, so an already-open editor has not
    started the server yet.
  * Open a .y file. Errors and warnings appear in Problems and in the gutter.

If VS Code says it cannot find yserve, set this in your settings -- it is the
durable answer, and it survives both an extension update and a rebuild:

    "y.lsp.serverPath": "$ROOT/yserve"

Then Developer: Reload Window. See src/tools/lsp/vscode-y-lang/README.md for
the other settings, and src/tools/lsp/LSP.md for what the server does.
EOF
