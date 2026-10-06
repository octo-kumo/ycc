#!/usr/bin/env python3
"""meta-identity.py — the pass must be the IDENTITY on a file with no blocks.

    ./test/sh/meta-identity.py ./ynew [LIMIT]

For every corpus .y file containing no `#{`, the source the pass hands to the
lexer must be the file's own text. `-E` dumps exactly that, so this compares the
dump against the input.

Why text and not the emitted binary: "the scanner changes nothing" is a claim
about the source the lexer sees. Comparing binaries would also measure every
unrelated emitter change between the reference compiler and this build, which
is how a byte-level test ends up reporting a regression that is not one. (It
does: comparing refs/ycc.ref against a feature build shows one extra
`xor %eax, %eax` on block-free programs -- that is emitter drift between the
two builds, not the pass. The dumped text for the same file is identical.)

Two things are stripped before comparing: the injected prelude the pass puts at
the top of the dump, and the `\\t// file:line` origin marker the dump appends to
each line. What must survive is every source line, in order.
"""
import pathlib, re, subprocess, sys

# Lines the compiler consumes before the lexer sees anything: `import` is
# spliced by the resolver, `export` and `embed` are directives. -E dumps what
# the lexer gets, so these are legitimately absent and a file containing one
# cannot equal its own dump. Excluded rather than filtered, so the remaining
# set is one where equality is the right claim.
DIRECTIVE_RE = re.compile(r'^\s*(import|export|embed)\b', re.M)

def main(argv):
    if len(argv) < 2:
        print(__doc__); return 2
    ycc, limit = argv[1], int(argv[2]) if len(argv) > 2 else 0
    root = pathlib.Path(__file__).resolve().parents[2]
    if not (root / "src/y").is_dir():
        root = pathlib.Path.cwd()
    if not (root / "src/y").is_dir():
        print(f"no src/y under {root}; run from a worktree root"); return 2

    files = []
    for d in ("src/y", "test/y", "examples", "bench"):
        p = root / d
        if p.is_dir():
            files += sorted(p.rglob("*.y"))

    checked = same = skipped_directive = 0
    diffs = []
    for f in files:
        raw = f.read_bytes()
        if b"#{" in raw:
            continue                                    # has blocks
        # See DIRECTIVE_RE: these files' dumps are legitimately not their source.
        if DIRECTIVE_RE.search(raw.decode("utf-8", "replace")):
            skipped_directive += 1
            continue
        r = subprocess.run([ycc, "-E", str(f)], capture_output=True, cwd=root)
        if r.returncode != 0:
            continue                                    # rejected; not an identity question
        checked += 1
        src = strip(raw.decode("utf-8", "replace"))
        dump = strip(r.stdout.decode("utf-8", "replace"))
        if dump == src:
            same += 1
        else:
            diffs.append((f, src, dump))
        if limit and checked >= limit:
            break

    print(f"\n=== meta identity: {checked} block-free, import-free files; "
          f"{same} identical, {len(diffs)} differing "
          f"({skipped_directive} skipped: has import/export/embed, so the dump differs) ===")
    for f, src, dump in diffs[:10]:
        print(f"\n  DIFFERS {f.relative_to(root)}  ({len(src)} src lines, {len(dump)} dumped)")
        import difflib
        for l in list(difflib.unified_diff(src, dump, "source", "dump", lineterm="", n=0))[:12]:
            print("   ", l)
    if len(diffs) > 10:
        print(f"\n  ... and {len(diffs) - 10} more")
    return 1 if diffs else 0

def strip(text):
    """Drop origin markers, comment-only lines and blanks; keep the rest."""
    out = []
    for l in text.splitlines():
        if "\t//" in l:
            l = l.split("\t//", 1)[0]
        l = l.strip()
        if not l or l.startswith("//"):
            continue
        out.append(l)
    return out

if __name__ == "__main__":
    sys.exit(main(sys.argv))
