#!/usr/bin/env python3
"""check-refs.py -- verify the references in this directory's LSP.md.

The document uses two kinds of reference, and this checks both.

1. SYMBOL references -- `types.check_program`, `native.origin_file`,
   `rename.rn_reaches_go`. This is the form used for compiler internals,
   because src/y moves constantly: a refactor shifts hundreds of lines, and a
   line citation goes stale the day it is written. Resolved against the source,
   so a rename is caught rather than silently absorbed.

2. file:line citations -- a handful, mostly into the LaTeX manual, which
   changes rarely. Resolved and reported with what is there now.

    python3 src/tools/lsp/check-refs.py        # from the repo root
    python3 src/tools/lsp/check-refs.py -v     # print every resolution

Exit 0 if everything resolves, 1 otherwise.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
DOC = os.path.join(HERE, "LSP.md")

MODULES = ("lexer", "parser", "types", "rename", "lint", "native", "asm",
           "elf", "arch_x64", "enc64", "dwarf", "pkg", "tags", "arch_x64")
# `lexer.y` is a filename, not `lexer` + a symbol called `y`
NOT_A_SYMBOL = {"y", "c", "h", "s", "md", "sh", "tex", "pack", "ref"}

SYMBOL = re.compile(r"\b(%s)\.([a-z_][a-z_0-9]*)" % "|".join(MODULES))
CITE = re.compile(
    r"(?<![\w/])((?:src/|docs/|test/|bench/|tools/)?[a-z_][a-z_0-9]*(?:/[a-z_0-9]+)*"
    r"\.(?:y|c|h|s|tex|md|sh))(?::(\d+)(?:-(\d+))?)?"
)
DEFINE = re.compile(r"^(?:def|type|let|const) ([a-z_][a-z_0-9]*)", re.M)
FENCE = re.compile(r"```.*?```", re.S)


def definitions(mod):
    f = os.path.join(ROOT, "src", "y", mod + ".y")
    if not os.path.isfile(f):
        return None
    return set(DEFINE.findall(open(f, encoding="utf-8", errors="replace").read()))


def resolve(path):
    for cand in (path, os.path.join("src", "y", path), os.path.join("src", "c", path)):
        if os.path.isfile(os.path.join(ROOT, cand)):
            return cand
    return None


def main():
    verbose = "-v" in sys.argv
    raw = open(DOC, encoding="utf-8").read()
    text = FENCE.sub("", raw)          # code blocks hold no citations
    fails = []

    defined = {m: definitions(m) for m in MODULES}
    defined = {m: d for m, d in defined.items() if d is not None}

    # ---- symbol references ------------------------------------------------
    total = good = 0
    seen = set()
    for m in SYMBOL.finditer(text):
        mod, sym = m.group(1), m.group(2)
        if sym in NOT_A_SYMBOL or (mod, sym) in seen:
            continue
        if mod not in defined:
            continue
        seen.add((mod, sym))
        total += 1
        if sym in defined[mod]:
            good += 1
            if verbose:
                print(f"  sym   {mod}.{sym}")
        else:
            fails.append(f"{mod}.{sym}: no `def`/`type`/`let` {sym!r} in src/y/{mod}.y")
    print(f"symbol references : {good}/{total} resolved")

    # ---- file:line citations ---------------------------------------------
    total = good = 0
    for m in CITE.finditer(text):
        path, lo, hi = m.group(1), m.group(2), m.group(3)
        real = resolve(path)
        if real is None:
            continue                      # a bare name for a file the plan creates
        if lo is None:
            continue
        total += 1
        lines = open(os.path.join(ROOT, real), encoding="utf-8", errors="replace").read().splitlines()
        n = len(lines)
        where = f"{path}:{lo}" + (f"-{hi}" if hi else "")
        if int(lo) > n or (hi and int(hi) > n):
            fails.append(f"{where}: out of range ({real} has {n} lines)")
        elif not lines[int(lo) - 1].strip():
            fails.append(f"{where}: blank line")
        else:
            good += 1
            if verbose:
                print(f"  line  {where} -> {lines[int(lo)-1].strip()[:52]}")
    print(f"file:line citations: {good}/{total} resolved")

    if fails:
        print(f"\nSTALE ({len(fails)}):")
        for f in fails:
            print(f"  {f}")
        print("\nA stale reference is worse than none: it reads as authoritative and")
        print("points at unrelated code. Prefer the symbol form; see the note at the")
        print("top of LSP.md.")
        return 1
    print("\nall references resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())