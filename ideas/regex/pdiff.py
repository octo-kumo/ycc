#!/usr/bin/env python3
"""Per-case diff of what the engine printed against what Python's re says
about the same bytes: run ideas/regex/run.sh (it builds and runs the fixture,
writing corpus.out), then this says where the two differ, case by case.
"""
import importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gen", os.path.join(HERE, "gen.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

def blocks(text):
    out, cur = [], []
    for line in text.split("\n"):
        if line.startswith("pat=") and cur:
            out.append("\n".join(cur))
            cur = [line]
        else:
            cur.append(line)
    if cur:
        out.append("\n".join(cur))
    return out

got = blocks(open(os.path.join(HERE, "corpus.out")).read())
want = blocks(open(os.path.join(os.path.dirname(HERE), "test", "y", "native", "t195_regex_corpus.expected")).read())
print("%d blocks got, %d want" % (len(got), len(want)))
only = sys.argv[1] if len(sys.argv) > 1 else ""

bad = 0
for i, (w, g) in enumerate(zip(want, got)):
    if w == g:
        continue
    # a case we know we spell differently, or one we support and Python does not
    if only and only not in repr(gen.CASES[i]):
        continue
    bad += 1
    print("=== %d %r on %r" % (i, gen.CASES[i][0], gen.CASES[i][1]))
    for wl, gl in zip(w.split("\n"), g.split("\n")):
        if wl != gl:
            print("   python %-44r ours %r" % (wl, gl))
    print()
print("%d/%d cases differ" % (bad, len(want)))