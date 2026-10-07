#!/usr/bin/env python3
"""Static reachability of a `ycc -S` listing: which emitted instructions can
never execute.

The tree shaker works on labels, so it can drop a whole function -- but it
cannot see that the instructions after an unconditional `jmp` or a `ret` are
dead, nor that a basic block nothing branches to (and nothing falls into) is
unreachable.  This reads the shaken listing and reports both, so a runtime
addition that leaves rubble behind is caught by a test instead of by reading
the disassembly.

Usage:
    ycc -S prog.y | test/sh/deadcode.py [-v] [--max N]

Exit status is 0 when the unreachable instruction count is <= N (default 0),
1 otherwise, so it can be a gate.  An indirect `jmp`/`call` is treated as a
jump to every label, which can only make the answer more conservative.
"""
import re
import sys

LABEL = re.compile(r"^([A-Za-z_.$][A-Za-z0-9_$.]*):")
INSN = re.compile(r"^\s+([a-z][a-z0-9]*)\s*(.*)$")
STOP = {"ret", "retq", "hlt", "ud2"}
DIRECTIVES = (".loc", ".byte", ".ascii", ".zero", ".quad", ".align",
              ".section", ".text", ".globl", ".data", ".long", ".string")


def parse(text):
    blocks = []      # [(label, [(mnemonic, operand, text), ...]), ...]
    labels = set()
    cur = None
    insns = []
    for raw in text.split("\n"):
        m = LABEL.match(raw)
        if m:
            if cur is not None or insns:
                blocks.append((cur, insns))
            cur = m.group(1)
            labels.add(cur)
            insns = []
            continue
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw[0] not in " \t":
            continue
        m = INSN.match(raw)
        if not m:
            continue
        mn, rest = m.group(1), m.group(2)
        if mn in DIRECTIVES:
            continue
        insns.append((mn, rest, raw.strip()))
    if cur is not None or insns:
        blocks.append((cur, insns))
    return blocks, labels


def succs(insns, index):
    """(successor block indices or "fall", dead-tail instruction texts)."""
    out = []
    dead = []
    stopped = False
    for _mn, _rest, text in insns:
        if stopped:
            dead.append(text)
            continue
        mn, rest = _mn, _rest.strip()
        if mn == "call":
            if rest.startswith("*"):
                out += list(index.values())
            elif rest in index:
                out.append(index[rest])
            continue
        if mn == "jmp" or mn.startswith("j"):
            if rest.startswith("*"):
                out += list(index.values())
            else:
                tgt = rest.split(",")[0].strip()
                if tgt in index:
                    out.append(index[tgt])
            if mn == "jmp":
                stopped = True
            continue
        if mn in STOP:
            stopped = True
    if not stopped:
        # Fall through: also for an EMPTY block, where two labels sit next to
        # each other (`ygiS_...:` right after `ygiE_...:`). Missing that makes
        # every label after a marker look unreachable.
        out.append("fall")
    return out, dead


def main():
    argv = sys.argv[1:]
    verbose = "-v" in argv
    argv = [a for a in argv if a != "-v"]
    limit = 0
    if "--max" in argv:
        i = argv.index("--max")
        limit = int(argv[i + 1])
        del argv[i:i + 2]
    text = sys.stdin.read() if not argv else open(argv[0]).read()

    blocks, labels = parse(text)
    index = {}
    for bi, (lab, _insns) in enumerate(blocks):
        if lab:
            index.setdefault(lab, bi)

    globl = set(re.findall(r"^\.globl\s+([A-Za-z_.$][A-Za-z0-9_$.]*)", text, re.M))
    roots = {"_start"} | globl
    # A label named from data (`.quad f`) is reachable through a value.
    for raw in text.split("\n"):
        st = raw.strip()
        if st.startswith(".") and not st.startswith(".globl"):
            for m in re.finditer(r"[A-Za-z_.$][A-Za-z0-9_$.]*", st):
                if m.group(0) in labels:
                    roots.add(m.group(0))

    edges = {}
    falls = {}
    dead_tails = {}
    for bi, (lab, insns) in enumerate(blocks):
        out, dead = succs(insns, index)
        edges[bi] = [o for o in out if isinstance(o, int)]
        falls[bi] = "fall" in out
        dead_tails[bi] = dead

    reach = set()
    work = [index[r] for r in roots if r in index]
    while work:
        bi = work.pop()
        if bi in reach:
            continue
        reach.add(bi)
        for nb in edges[bi]:
            work.append(nb)
        if falls[bi] and bi + 1 < len(blocks):
            work.append(bi + 1)

    dead_insns = []
    for bi, (lab, insns) in enumerate(blocks):
        if bi not in reach:
            dead_insns += [t for _m, _o, t in insns]
        else:
            dead_insns += dead_tails[bi]

    if verbose:
        for bi, (lab, insns) in enumerate(blocks):
            if bi not in reach and insns:
                print("unreachable block %s:" % lab)
                for _m, _o, t in insns:
                    print("    %s" % t)
        for bi, (lab, _insns) in enumerate(blocks):
            for t in dead_tails.get(bi, []):
                print("dead tail in %s: %s" % (lab, t))
    nblocks = len([1 for bi in range(len(blocks)) if bi not in reach])
    print("deadcode: %d unreachable instruction(s) in %d block(s)"
          % (len(dead_insns), nblocks))
    return 0 if len(dead_insns) <= limit else 1


if __name__ == "__main__":
    sys.exit(main())
