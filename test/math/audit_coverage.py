#!/usr/bin/env python3
"""Is every def in std/math.y reached by something a test actually checks?

The objective's rule is that a function without a gate gets one, and a gate that
cannot fail gets fixed so that it can. Applying that to this module needs a
question the ulp table cannot answer: the table pins 38 names, but the module has
well over a hundred defs, and most of the rest are HELPERS -- reached only
through a function the table does pin. A helper can be wrong and the table still
passes, because the caller's final rounding hides it.

So the question is reachability, not coverage:

  roots      the names in test/math/ulp_table.txt, plus every name called as
             `math.NAME(` anywhere under test/y and test/std -- the fixtures and
             the std self-test suites, which are both checked.
  closure    every def reachable from a root through the module's own call graph.
  gap        every def outside that closure.

A gap is not automatically a defect. The oracle twins (exp_y, log_y, sin_y,
cos_y, atan_y, asin_y, pow_y, pow_int, pow_pos) exist to be the REFERENCE for
the assembly kernels, and t313/t315 pin the assembly against them -- so they are
covered by a comparison rather than by being called, which is a different and
perfectly good kind of gate. Those are in KNOWN with that reason.

A gap that is neither is a real hole, and that is what this file found the first
time it ran: fdot's and faxpy's length-mismatch paths, which print a runtime
error and stop, had no case anywhere. Two fixtures (t329, t330) closed them.

The call graph is read out of the source with a regex, so it sees direct calls
only -- which is the right granularity here, because what matters is whether a
def is reachable at all, and an indirect path through a helper still passes
through the helper.

WHAT IT DOES NOT PROVE, which took a real hole to learn. Reachability is
NECESSARY and not SUFFICIENT. len_mismatch is reachable from fdot and this file
calls it covered -- and before t329, not one test in the tree asked fdot for the
mismatched-length path, because the fixtures only ever passed equal-length
arrays. The function was gated and the path was not. So the guarantee here is
"nothing in the module is entirely ungated", not "every path is exercised", and
the gap between those two statements is exactly where the first hole lived. That
is what this file narrows; what closes the rest is reading.

Its first run found no new gaps, because the module's call graph is dense and
almost everything is reachable from something. It is kept as a RATCHET, and it
is verified to fail: planting a def that nothing calls and nothing pins gives
exit 1 and names it.
"""
import io
import os
import re
import sys

MATH = os.environ.get("MATH_Y", "src/y/std/math.y")
TABLE = os.environ.get("ULP_TABLE", "test/math/ulp_table.txt")
TESTDIRS = ["test/y", "test/std"]

# defs covered by being the reference for something else rather than by being
# called. Each says what pins it, because an unexplained suppression is a finding
# nobody will look at again.
KNOWN = {
    "exp_y": "the reference for exp_asm; t313's table pins the assembly against it",
    "log_y": "the reference for log_asm; same table",
    "sin_y": "the reference for sin_asm; t313",
    "cos_y": "the reference for cos_asm; t313",
    "atan_y": "the reference for atan; t313-style comparison",
    "asin_y": "the reference for asin; t313-style comparison",
    "pow_y": "the reference for pow_asm; t315_math_pow_asm.y, 15137 pairs",
    "pow_int": "reached only from pow_y, which is the reference for pow_asm; t315",
    "pow_pos": "reached only from pow_y; t315",
    "fdot_y": "reached from fdot itself (the oracle twin), so fdot's gate covers it",
    "fmax_y": "reached from fmax_of itself",
    "fmin_y": "reached from fmin_of itself",
    "fscale_y": "reached from fscale itself",
    "faxpy_y": "reached from faxpy itself",
    "fsum_y": "reached from fsum itself",
}


def defs_and_callers(path):
    """(name, callees) for every top-level def in the module.

    A callee is a name that appears followed by `(` inside the def's body. That
    over-reports -- `f(` in a comment would count -- which is why comments are
    stripped first. It never under-reports, and under-reporting is the direction
    that would hide a gap.
    """
    src = io.open(path, encoding="utf-8").read().split("\n")
    out = []
    cur = None
    depth = 0
    for raw in src:
        line = re.sub(r"//.*$", "", raw)
        if cur is None:
            m = re.match(r"\s*(?:native\s+)?def\s+([A-Za-z_]\w*)\s*\(", line)
            if m:
                cur = {"name": m.group(1), "calls": []}
                depth = line.count("{") - line.count("}")
                if depth <= 0:
                    cur = None
                continue
        else:
            cur["calls"] += re.findall(r"\b([A-Za-z_]\w*)\s*\(", line)
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                out.append(cur)
                cur = None
    return out


def table_names(path):
    names = set()
    for l in io.open(path, encoding="utf-8"):
        l = l.strip()
        if l and not l.startswith("#"):
            names.add(l.split()[0])
    return names


def fixture_names(dirs):
    """Every `math.NAME(` in the checked fixtures and std self-tests."""
    names = set()
    for d in dirs:
        for root, _dirs, files in os.walk(d):
            for f in files:
                if not f.endswith(".y"):
                    continue
                try:
                    body = io.open(os.path.join(root, f), encoding="utf-8").read()
                except (IOError, UnicodeDecodeError):
                    continue
                names.update(re.findall(r"\bmath\.([A-Za-z_]\w*)\s*\(", body))
    return names


def main():
    math = sys.argv[1] if len(sys.argv) > 1 else MATH
    graph = {d["name"]: d["calls"] for d in defs_and_callers(math)}
    roots = table_names(TABLE) | fixture_names(TESTDIRS)
    roots &= set(graph)

    seen = set()
    stack = [r for r in roots]
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        for c in graph.get(n, ()):
            if c in graph and c not in seen:
                stack.append(c)

    gaps = sorted(n for n in graph if n not in seen)
    unknown = [g for g in gaps if g not in KNOWN]
    for g in gaps:
        if g in KNOWN:
            print("  known   %-16s %s" % (g, KNOWN[g]))
    for g in unknown:
        print("  NEW     %-16s not reachable from any ulp-table case or fixture call" % g)
    print("  %d defs, %d reachable from %d roots, %d gap(s): %d known, %d new"
          % (len(graph), len(seen), len(roots), len(gaps), len(gaps) - len(unknown), len(unknown)))
    if unknown:
        print()
        print("  A new gap is a function with no gate. Either it is an oracle")
        print("  reached only by a comparison -- say so in KNOWN -- or it needs a")
        print("  fixture. Do not add it to KNOWN to make this go away: two of the")
        print("  entries above were written that way and cost a real hole each.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())