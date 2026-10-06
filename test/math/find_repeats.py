#!/usr/bin/env python3
"""Find the same computation written twice under two names, in std/math.y.

WHY THIS EXISTS. The objective names a defect class -- "a behaviour decided by
an accident of expression order" -- and the accident need not be in the ORDER.
It can be in the SPELLING: two places that mean the same thing and are written
differently, so a later change fixes one and not the other. That is exactly how
sin_cos_k came to compute x*x THREE times -- twice inline on the sin line and
once as `w` on the next -- the multiplier and the kernel's argument agreeing only
by accident, and it was found by reading, not by a tool. A defect worth finding
twice wants a finder.

THE THREE REPORTS, and what each one cannot see. All three are text-level, and
each was wrong in a way worth writing down:

  REPEATED        the same subexpression more than once in one function. Every
                  hit is a place a change can land on one side only. Noisy by
                  nature: most are intentional (`a * b` twice), so this is a
                  reading list, not a defect list.

  DIVERGENT       two subexpressions equal as mathematics and different as
                  text, once commutative operands are sorted -- a*b against b*a.
                  Sorting is what makes it findable at all; a pure text
                  comparison finds nothing. Empty in math.y at present.

  BOUND ELSEWHERE a `let` whose value is a COMPUTATION, spelled out again
                  somewhere in the same function instead of being named. This is
                  the one that bites, and it is invisible to a text comparison
                  because the two spellings are not on the same line.

THE FALSE POSITIVES, because a finder that cannot say what it gets wrong is not
a finder. BOUND ELSEWHERE needed two filters, added in that order after being
wrong without them:

  - Writes. cbrt binds `y2 = y * y` after a Newton loop that itself contains
    `y * y` -- and the loop's LAST statement REBINDS y, so the two are different
    numbers and the code is right. split_mantissa binds `ef = exp_field(r)` and
    recomputes it inside the doubling loop on purpose, because r changed. Both
    were reported first; both are the same mistake, of trusting text over flow.
  - Branch disjointness, NOT yet filtered, and this is a known false positive:
    atan's `let neg = x < 0.0` sits in the else arm and the `x < 0.0` it matches
    sits in the is_inf arm, so exactly one of the two ever runs. It is in KNOWN
    for that reason rather than in a filter, because deciding the arms are
    mutually exclusive needs real control flow and a line-based scan cannot.

SO: two reports, one real redundancy (fvariance computes len(a) twice) and one
known false positive (atan). Both are in KNOWN, and anything new is a failure.
That makes this a RATCHET: the list can shrink, and a new entry has to come with
a reason.

Line-based and bracket-aware: expressions are recovered by walking brackets and
operators, which is enough for a module written the way math.y is. It would need
a real parser to be worth anything on other input, and it is deliberately not
one -- a detector that guesses is worse than one that says what it does.
"""
import io
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict

MATH = os.environ.get("MATH_Y", "src/y/std/math.y")

# Findings this file knows about and accepts. Each carries WHY it is acceptable,
# because a bare list of suppressions is a list of things nobody will ever look
# at again. A finding not here fails the run.
KNOWN = {
    ("atan", 1911, "x<0.0"): (
        "the matching test is in the is_inf arm and this binding in the else "
        "arm, so only one of the two ever runs"),
    ("fvariance", 2933, "len(a)"): (
        "real but tiny: len is a header load, and the guard is a length "
        "comparison. Hoisting it would save a few instructions a call on a "
        "kernel that spends its time on the elements, at the cost of binding a "
        "name before the guard that decides whether the rest runs"),
}


def strip_comments(line):
    out = []
    i = 0
    while i < len(line):
        c = line[i]
        if c == '"':
            j = i + 1
            while j < len(line) and line[j] != '"':
                j += 2 if line[j] == "\\" else 1
            out.append(line[i:j + 1])
            i = j + 1
            continue
        if line[i:i + 2] == "//":
            break
        out.append(c)
        i += 1
    return "".join(out)


def atoms(s):
    """Split an expression into atoms, keeping bracketed groups whole.

    Returns (text, depth) pairs; depth 1 for a group, 0 for a bare atom.
    """
    out = []
    buf = ""
    i = 0
    while i < len(s):
        c = s[i]
        if c in "([{":
            j = i
            depth = 0
            while j < len(s):
                if s[j] in "([{":
                    depth += 1
                elif s[j] in ")]}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if buf.strip():
                out.append((buf.strip(), 0))
            out.append((s[i:j + 1], 1))
            buf = ""
            i = j + 1
            continue
        if c == " ":
            if buf:
                out.append((buf, 0))
            buf = ""
            i += 1
            continue
        buf += c
        i += 1
    if buf:
        out.append((buf, 0))
    return out


def groups(s, depth=0):
    """Every bracketed group at ANY depth, outermost first.

    Top level only would miss the case that motivated this file: in
    `x * (1.0 + x * x * poly_split(sin_k, sin_kl, x * x))` the `x * x` sits
    inside a group, so a shallow scan sees one atom and finds nothing. Bounded,
    so a pathological nest cannot spin.
    """
    out = []
    if depth > 12:
        return out
    for txt, d in atoms(s):
        if d == 1 and txt[1:-1].strip():
            out.append(txt[1:-1].strip())
            out.extend(groups(txt[1:-1], depth + 1))
    return out


def canon(text):
    """A canonical form for comparison: commutative operands sorted, spacing
    and redundant parens dropped. `a * b` and `b*a` become one thing."""
    t = re.sub(r"\s+", "", text)
    while re.fullmatch(r"\(([^()]*)\)", t):
        t = re.fullmatch(r"\(([^()]*)\)", t).group(1)
    for op in ("*", "+"):
        m = re.fullmatch(r"(.+?)%s(.+)" % re.escape(op), t)
        if m and not any(c in m.group(1) + m.group(2) for c in "([{"):
            a, b = canon(m.group(1)), canon(m.group(2))
            lo, hi = sorted((a, b))
            return "%s(%s%s%s)" % (op, lo, op, hi)
    return t


def functions(path):
    """(name, line, body lines) for every def, at the brace level."""
    src = io.open(path, encoding="utf-8").read().split("\n")
    out = []
    cur = None
    depth = 0
    for n, raw in enumerate(src, 1):
        line = strip_comments(raw)
        if cur is None:
            m = re.match(r"\s*(?:native\s+)?def\s+([A-Za-z_][\w]*)", line)
            if m:
                cur = {"name": m.group(1), "line": n, "body": []}
                depth = line.count("{") - line.count("}")
                if depth <= 0:
                    cur = None
                continue
        else:
            cur["body"].append((n, line))
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                out.append(cur)
                cur = None
    return out


def roots(expr):
    return set(re.findall(r"[A-Za-z_]\w*", expr))


def writes_between(f, a, b):
    """Names assigned anywhere between two lines, inclusive.

    This is the filter that turned the report from noise into findings. Without
    it, cbrt's `let y2 = y * y` is flagged against the `y * y` inside the Newton
    loop above it -- where the loop's last statement rebinds y, so the two are
    different numbers and the code is correct.
    """
    out = set()
    lo, hi = (a, b) if a <= b else (b, a)
    for n, line in f["body"]:
        if n < lo or n > hi:
            continue
        st = line.strip()
        m = re.match(r"(?:let\s+)?([A-Za-z_]\w*)\s*(?:=[^=]|\+=|-=|\*=|/=|%=|\+\+|--|\[)", st)
        if m:
            out.add(m.group(1))
            continue
        for m in re.finditer(
                r"(?:^|[\s(\[,+\-*/])([A-Za-z_]\w*)\s*(\[|=[^=]|\+=|-=|\*=|/=|%=|\+\+|--)", st):
            out.add(m.group(1))
    return out


def bindings(f):
    """(line, name, canonical value, raw value) for each let in a function."""
    out = []
    for n, line in f["body"]:
        m = re.match(r"\s*let\s+([A-Za-z_]\w*)\s*=\s*(.+?);\s*$", line.strip())
        if m:
            out.append((n, m.group(1), canon(m.group(2)), m.group(2)))
    return out


def bound_elsewhere(f):
    """A let whose value is a computation, written out again instead of named."""
    found = []
    for n, name, cval, cval_raw in bindings(f):
        raw = re.sub(r"\s+", "", cval_raw)
        # An alias or a constant is NAMING, not recomputation. `let r1 = m`
        # gives a second name to something that already exists, and reporting
        # that buries the finding under six lines of nothing.
        if re.fullmatch(r"[A-Za-z_]\w*|[-+0-9.eExXa-fA-F_]+", raw):
            continue
        clean, setaside = [], []
        for m2, line2 in f["body"]:
            if m2 == n:
                continue
            if not spelled(line2, cval_raw):
                continue
            (setaside if roots(cval_raw) & writes_between(f, n, m2) else clean).append(m2)
        if clean:
            found.append((name, cval, n, sorted(set(clean)), sorted(set(setaside))))
    return found


def count_spelled(line, value):
    """How many whole-token times the value's text appears in this line.

    A COUNT, not a yes/no, and the distinction is the whole detector. The plant
    for it is `let p = a * b + (a * b) * 2.0`, where `a * b` occurs twice -- and
    a scan that asks "is this group present?" answers yes once and misses the
    repetition entirely. Asking "is `a * b` a group here?" answers no both
    times, because only the second one is parenthesised. Both were tried before
    this one worked.
    """
    flat = re.sub(r"\s+", "", line)
    body = re.sub(r"\s+", "", value).strip("()")
    n = 0
    k = flat.find(body)
    while k >= 0:
        before = flat[k - 1] if k else ""
        after = flat[k + len(body)] if k + len(body) < len(flat) else ""
        if not (before.isalnum() or before == "_") and \
           not (after.isalnum() or after == "_"):
            n += 1
        k = flat.find(body, k + 1)
    return n


def spelled(line, value):
    """Does this line contain the value's text, whole-token?

    Two ways to look, because neither catches everything. The canonical-group
    test sees `x * x` when it is parenthesised; the literal test sees it when it
    is not, which is the common case and the one sin_cos_k was. The identifier
    guard stops `x` matching inside `xy`.
    """
    flat = re.sub(r"\s+", "", line)
    body = re.sub(r"\s+", "", value).strip("()")
    k = flat.find(body)
    while k >= 0:
        before = flat[k - 1] if k else ""
        after = flat[k + len(body)] if k + len(body) < len(flat) else ""
        if not (before.isalnum() or before == "_") and \
           not (after.isalnum() or after == "_"):
            return True
        k = flat.find(body, k + 1)
    return any(canon(g) == canon(value) for g in groups(line))


def repeated(path):
    """A subexpression written more than once inside one function.

    Counted as OCCURRENCES across the function's lines, not as lines. The
    difference is the common case: `let p = a * b + (a * b) * 2.0` repeats on one
    line, and a report keyed on line numbers sees one line and calls it once.
    Counting occurrences rather than lines is also what makes the two cases --
    the same pair twice in one expression, and once on each of two lines -- the
    same finding, which is right, because they are the same hazard: a change to
    one occurrence does not reach the other.
    """
    rep = {}
    for f in functions(path):
        body = [(n, line.strip().rstrip(";").rstrip()) for n, line in f["body"]]
        cands = set()
        for n, st in body:
            if st and st not in ("{", "}"):
                cands.update(g for g in groups(st) if canon(g) not in ("0", "1", "0.0", "1.0", ""))
        for c in cands:
            hits = []
            for n, st in body:
                k = count_spelled(st, c)
                if k:
                    hits.append((n, k))
            if sum(k for _, k in hits) > 1:
                rep[(f["name"], canon(c))] = hits
    return rep


def divergent(path):
    out = defaultdict(list)
    for f in functions(path):
        for n, line in f["body"]:
            s = line.strip().rstrip(";").rstrip()
            seen = set()
            for g in groups(s):
                c = canon(g)
                for prev in seen:
                    if prev[0] == c and prev[1] != g:
                        out[(f["name"], n)].append((prev[1], g))
                seen.add((c, g))
    return out


def bound(path):
    out = []
    for f in functions(path):
        for name, cval, n, hits, setaside in bound_elsewhere(f):
            out.append((f["name"], n, re.sub(r"\s+", "", cval), hits, setaside))
    return out


# The self-test plants one of each thing this file claims to find, and the point
# is not that it passes -- it is that a change to the detectors cannot quietly
# stop detecting. A finder that finds nothing has no evidence that it works.
PLANTS = {
    "bound elsewhere": """
def planted(x: float) -> float {
    let s = x * (1.0 + x * x * f(x * x));
    let w = x * x;
    w + s
};
""",
    "commutative divergence": """
def planted(a: float, b: float) -> float {
    let p = (a * b) * (b * a);
    p
};
""",
    "repeated": """
def planted(a: float, b: float) -> float {
    let p = a * b + (a * b) * 2.0;
    p
};
""",
}


def selftest():
    fails = []
    for what, body in PLANTS.items():
        with tempfile.NamedTemporaryFile("w", suffix=".y", delete=False) as fh:
            fh.write(body)
            path = fh.name
        try:
            rep = repeated(path)
            bnd = [(f, n, c, h, s) for f, n, c, h, s in bound(path)]
            div = divergent(path)
            got = {"bound elsewhere": bnd, "repeated": list(rep.values()),
                   "commutative divergence": [p for v in div.values() for p in v]}
            if not got[what]:
                fails.append("%s: planted but NOT found -- the detector for it is broken" % what)
            else:
                print("  ok      the '%s' detector finds its plant (%d)" % (what, len(got[what])))
        finally:
            os.unlink(path)
    if fails:
        for f in fails:
            print("  FAILED  " + f)
        return 1
    return 0


def main():
    if "--selftest" in sys.argv:
        return selftest()
    path = sys.argv[1] if len(sys.argv) > 1 else MATH
    unknown = []
    for fname, n, cval, hits, setaside in bound(path):
        key = (fname, n, cval)
        why = KNOWN.get(key)
        if why is None:
            unknown.append((fname, n, cval, hits, setaside))
        else:
            print("  known   %-12s line %-5d %-16s also on %s -- %s"
                  % (fname, n, cval, ", ".join(str(h) for h in hits), why))
        if setaside:
            print("  setaside %-11s line %-5d %-16s also on %s, but a name it reads is written in between"
                  % (fname, n, cval, ", ".join(str(h) for h in setaside)))
    for fname, n, cval, hits, setaside in unknown:
        print("  NEW     %-12s line %-5d %-16s spelled out again on %s"
              % (fname, n, cval, ", ".join(str(h) for h in hits)))
    print("  %d finding(s) new, %d accepted, over %s"
          % (len(unknown), len(KNOWN), path))
    if unknown:
        print("  A new one is a defect or needs a reason in KNOWN. It is not")
        print("  automatically wrong: see the two false positives documented at")
        print("  the top of this file before adding a third.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())