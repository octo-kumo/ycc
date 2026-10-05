#!/usr/bin/env python3
"""check-names.py -- no two path-imported modules may define the same name.

A Y `import x from "path"` FLATTENS `x` into the importing file's namespace: the
names are not qualified, they are simply merged. A by-name import (`import fs;`)
keeps its namespace and is safe. Every module in src/tools/lsp/ imports the
compiler by path, so all of them -- and the compiler -- share ONE namespace.

A collision is therefore not a tidy error. Depending on which pair, you get:

  * `duplicate definition 'X': ... defines it too` -- caught, but reported
    against the wrong file, with no hint that the LSP is the cause;
  * or nothing at all, and one definition silently shadowing the other. That is
    the expensive one. It happened five times while building the server, and the
    worst case was `type Tok`, which shadowed src/y/lexer.y's own token type and
    produced 60 errors inside the compiler, none of them in the file that caused
    them.

So the check is static and it covers THREE directions:

  * LSP name vs the compiler's -- src/y/*.y and src/y/std/*.y, which is 20k lines
    of vocabulary;
  * LSP name vs another LSP module -- pos.Doc and serve.Doc collided the same way;
  * an LSP module's BASENAME vs a dot-accessed name in the compiler. This one is
    not a name collision at all but it breaks the same way, and worse: the
    module `index.y` made every `index.idx` in types.y a module reference and
    produced 42 "undefined variable" errors in the compiler, reported against
    types.y with nothing pointing at the cause. See check_basenames.

Exit 0 iff every name is unique across all of them and no basename is
dot-accessed.

    python3 src/tools/lsp/check-names.py
"""

import os
import re
import sys

# .../src/tools/lsp/check-names.py -> the repository root is four levels up
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
LSP = os.path.dirname(os.path.abspath(__file__))

# A definition the splicer strips, so it cannot collide: the export line is
# deleted before the files share a namespace.
SKIP_KINDS = {"export"}

DEF = re.compile(r"^(def|type|const)\s+([A-Za-z_][A-Za-z_0-9]*)")


def defined_names(path):
    """(name, kind, lineno) for every top-level definition in a Y file."""
    out = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f, 1):
            # A `#` comment line cannot define anything, and a line inside a
            # block comment would be a false positive -- the Y sources use /* */
            # for long explanations, so tracking that matters.
            if line.lstrip().startswith("#"):
                continue
            m = DEF.match(line)
            if m and m.group(1) not in SKIP_KINDS:
                out.append((m.group(2), m.group(1), n))
    return out


def strip_comments(text):
    """Text with /* */ and // comments blanked, so a commented-out def is not
    counted and a `def` inside a block comment is not either."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                if text[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def collect(files, label):
    found = {}
    for f in files:
        with open(f, "r", encoding="utf-8", errors="replace") as fh:
            clean = strip_comments(fh.read())
        for name, kind, line in defined_names_from_text(clean, f):
            found.setdefault(name, []).append((label, kind, os.path.basename(f), line))
    return found


def defined_names_from_text(text, path):
    out = []
    for n, line in enumerate(text.split("\n"), 1):
        m = DEF.match(line)
        if m and m.group(1) not in SKIP_KINDS:
            out.append((m.group(2), m.group(1), n))
    return out


def check_basenames(lsp_files, compiler):
    """No module BASENAME may be dot-accessed anywhere in the compiler.

    This is a different failure from the two above, and it is quieter. An
    `import x from "..."` binds `x`, and native.strip_ns then rewrites every
    `x.field` in the WHOLE program as a qualified module reference -- including
    the ones written against a local variable that happens to share the name.

    So a module called `index.y` rewrote the compiler's own `index.idx` and
    `index.arr` -- 42 reads in src/y -- into module-qualified names that do not
    exist, and every one came back as "undefined variable" from inside types.y,
    with nothing pointing at the server. It was renamed to `scope.y`.

    The rule is not "the name must be unused": `pos` is bound by pos.y and the
    compiler has 24 locals named `pos`, which is fine, because `pos.` is never
    written. What matters is the dot access, because that is the only spelling
    strip_ns can mistake for a module reference.
    """
    bad = 0
    bases = sorted(os.path.splitext(os.path.basename(f))[0] for f in lsp_files)
    for f in compiler:
        try:
            with open(f, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        for n, text in enumerate(lines, 1):
            # skip comment-only lines: a name in prose is not code
            stripped = text.lstrip()
            if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*"):
                continue
            for base in bases:
                if re.search(r"\b%s\s*\." % re.escape(base), text):
                    bad += 1
                    print("")
                    print("BASENAME HAZARD  `%s.` in %s:%d" % (base, f, n))
                    print("  the module %s.y binds `%s`, and strip_ns rewrites" % (base, base))
                    print("  every `%s.something` as a qualified module reference." % base)
                    print("  Rename the module (check-names.py cannot rename it for you).")
    print("")
    print("module basenames: %d checked, %d dot-accessed by the compiler"
          % (len(bases), bad))
    return bad


def main():
    lsp_files = sorted(
        os.path.join(LSP, f) for f in os.listdir(LSP) if f.endswith(".y")
    )
    if not lsp_files:
        print("check-names: no LSP modules found at %s" % LSP, file=sys.stderr)
        return 2

    compiler = []
    for d in ("src/y", "src/y/std"):
        p = os.path.join(ROOT, d)
        if not os.path.isdir(p):
            continue
        for f in sorted(os.listdir(p)):
            if f.endswith((".y",)):
                compiler.append(os.path.join(p, f))

    # std/json.y is imported BY NAME, so it keeps its namespace and cannot
    # collide. It is excluded from the compiler side on purpose -- `json.obj`,
    # `json.str` and `json.index` are perfectly good names precisely because
    # nothing is flattened.
    json_mod = os.path.join(ROOT, "src", "y", "std", "json.y")
    compiler = [f for f in compiler if f != json_mod]

    lsp = collect(lsp_files, "lsp")
    comp = collect(compiler, "compiler")

    lsp_names = len(lsp)
    print("LSP modules: %d files, %d distinct names" % (len(lsp_files), lsp_names))
    print("compiler:    %d files, %d distinct names" % (len(compiler), len(comp)))

    bad = 0
    cross = sorted(set(lsp) & set(comp))
    for name in cross:
        bad += 1
        print("")
        print("COLLISION  %s" % name)
        for where, kind, f, line in comp[name][:2]:
            print("  compiler  %s %s:%d" % (kind, f, line))
        for where, kind, f, line in lsp[name][:2]:
            print("  lsp       %s %s:%d" % (kind, f, line))

    within = []
    for name, places in sorted(lsp.items()):
        if len(places) > 1:
            within.append((name, places))
    for name, places in within:
        bad += 1
        print("")
        print("COLLISION (lsp-internal)  %s" % name)
        for where, kind, f, line in places:
            print("  lsp  %s %s:%d" % (kind, f, line))

    bad += check_basenames(lsp_files, compiler)

    print("")
    if bad:
        print("%d collision(s). A path import flattens, so rename one of each" % bad)
        print("(see the header of this file, and LSP.md section 5).")
        return 1
    print("no collisions: every LSP name is unique among the LSPs and the compiler,")
    print("and no module basename is dot-accessed by the compiler")
    return 0


if __name__ == "__main__":
    sys.exit(main())
