#!/usr/bin/env python3
"""The parts every kernel generator shares.

A kernel in src/y/arch/math.s is generated from src/y/std/math.y rather than
written by hand, and the reason is narrow and worth stating once: the promise is
that the assembly returns the same double as the Y, so a table of constants that
somebody retyped is a table that can disagree with the oracle, and nothing in the
build would notice. So the generators here READ the module's own `let` lines.

Two more things live here because every generator needs them and both are traps:

* comments are whole flush-left lines. `arch_asm_lines` drops a line only when its
  first byte is `#`, so a comment trailing an instruction reaches the assembler
  and is read as an operand -- `L###: bad operand`, on a line whose opcode the
  prelude uses everywhere. `make asm-check` passes such a line, because GNU as
  reads trailing comments and this assembler does not.
* a constant is emitted as a decimal `.quad` of its IEEE-754 PATTERN, which is
  why `bits()` reads it as a signed long (a negative pattern is half of every
  double's) and why the assembler had to learn to accept a negative `.quad`.
"""
import re
import struct

MATHY = "src/y/std/math.y"


def bits(v: float) -> int:
    """A double's bit pattern, as the signed long it reads as in assembly."""
    return struct.unpack("<q", struct.pack("<d", v))[0]


def let_float(name: str, src: str = None) -> float:
    """The `let NAME: float = ...;` constant."""
    src = open(MATHY).read() if src is None else src
    m = re.search(r"^let %s: float = ([-0-9.eE+]+);" % name, src, re.M)
    assert m, "no such constant: " + name
    return float(m.group(1))


def let_floats(name: str, src: str = None) -> list:
    """The `let NAME: [float] = [...];` coefficient list, in order."""
    src = open(MATHY).read() if src is None else src
    m = re.search(r"^let %s: \[float\] = \[(.*?)\];" % name, src, re.S | re.M)
    assert m, "no such table: " + name
    out = []
    for tok in m.group(1).split(","):
        tok = tok.strip()
        if not tok:
            continue
        if tok.startswith("- "):
            tok = "-" + tok[2:]
        out.append(float(tok))
    return out


class Table:
    """One table, one label.

    A label per entry costs the shaker ~2K instructions of label-map fixpoint
    each, on every compile of every program, which is why a kernel reads
    `tab+0`, `tab+8`, `tab+16` and not four names.
    """

    def __init__(self, label: str, title: str):
        self.label = label
        self.title = title
        self.entries = []
        self.offs = {}

    def add(self, name: str, value: float) -> str:
        """Add an entry; return the text a routine reads it by."""
        assert name not in self.offs, name
        self.offs[name] = 8 * len(self.entries)
        self.entries.append((name, bits(value)))
        return self.ref(name)

    def ref(self, name: str) -> str:
        return "%s+%d(%%rip)" % (self.label, self.offs[name])

    def block(self) -> str:
        # The name goes on a line of its own, for the same reason every other
        # comment here does: a `.quad`'s value is the whole rest of the line, so
        # a trailing comment becomes part of it -- `bad .quad value
        # '4604544271217802189    # isqrt2'`.
        out = ["# " + self.title, self.label + ":"]
        for name, b in self.entries:
            out.append("# " + name)
            out.append("    .quad %d" % b)
        out.append("")
        return "\n".join(out)


class Writer:
    """The assembly lines, with every comment on a line of its own."""

    def __init__(self):
        self.lines = []

    def w(self, line: str = "") -> None:
        body, sep, tail = line.partition("  #")
        if sep and not body.lstrip().startswith("#"):
            self.lines.append("#" + tail)
            self.lines.append(body)
        else:
            self.lines.append(line)

    def text(self) -> str:
        return "\n".join(self.lines) + "\n"


def emit(out_path, w: Writer, *tables: Table) -> None:
    text = w.text()
    for t in tables:
        text += "\n" + t.block()
    if out_path:
        open(out_path, "w").write(text)
    else:
        print(text)