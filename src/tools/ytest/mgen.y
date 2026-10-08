// mgen.y -- what every kernel generator shares (`ytest math-gen`).
//
// A kernel in src/y/arch/math.s is generated from src/y/std/math.y rather than
// written by hand, and the reason is narrow: the promise is that the assembly
// returns the same double as the Y, so a table of constants somebody retyped is
// a table that can disagree with the oracle, and nothing in the build would
// notice. So the generators READ the module's own `let` lines.
//
// Two more things live here because every generator needs them and both are
// traps:
//
// * comments are whole flush-left lines. `arch_asm_lines` drops a line only when
//   its first byte is `#`, so a comment trailing an instruction reaches the
//   assembler and is read as an operand. `make asm-check` passes such a line,
//   because GNU as reads trailing comments and this assembler does not.
// * a constant is emitted as a decimal `.quad` of its IEEE-754 PATTERN, read as
//   a signed long (a negative pattern is half of every double's).
import math;
import yt;
import yc;
import mstatic;

/** One table, one label: a label per entry costs the shaker ~2K instructions of
label-map fixpoint each, on every compile, so a kernel reads `tab+0`, `tab+8`. */
type Table = { label: str, title: str, names: [str], vals: [long] };

/** The assembly lines, with every comment on a line of its own. */
type Writer = { lines: [str] };

/** Stop the generator: a table it cannot read is a routine it must not write. */
def die(m: str) {
    eputs("math-gen: " + m + "\n");
    exit(2);
};

def src() -> str { yt.read(yc.ROOT + "/src/y/std/math.y") };

def bits(v: float) -> long { math.fbits(v) };

/** The `let NAME: float = ...;` constant. */
def let_float(s: str, name: str) -> float {
    let key = "\nlet " + name + ": float = ";
    let i = s.index_of(key);
    if (i < 0) { die("no such constant: " + name); };
    let j = i + key.length;
    let k = j;
    while (k < s.length && s.byte_at(k) != 59) { k += 1; };
    mstatic.parse_float(s[j:k])
};

/** The `let NAME: [float] = [...];` coefficient list, in order. */
def let_floats(s: str, name: str) -> [float] {
    let key = "\nlet " + name + ": [float] = [";
    let i = s.index_of(key);
    if (i < 0) { die("no such table: " + name); };
    let j = i + key.length;
    let k = j;
    while (k + 1 < s.length && !(s.byte_at(k) == 93 && s.byte_at(k + 1) == 59)) { k += 1; };
    let out: [float] = [];
    foreach (tok in s[j:k].split(",")) {
        let t = tok.trim();
        if (t != "") {
            if (t.starts_with("- ")) { t = "-" + t[2:]; };
            out += mstatic.parse_float(t);
        };
    };
    out
};

def table(label: str, title: str) -> Table { { label: label, title: title, names: [], vals: [] } };

def ref(t: Table, name: str) -> str {
    let i = 0;
    while (t.names[i] != name) { i += 1; };
    t.label + "+" + tostring(8 * i) + "(%rip)"
};

/** Add an entry; answer the text a routine reads it by. */
def add(t: Table, name: str, v: float) -> str {
    t.names += name;
    t.vals += bits(v);
    ref(t, name)
};

// The name goes on a line of its own: a `.quad`'s value is the whole rest of
// the line, so a trailing comment would become part of it.
def block(t: Table) -> str {
    let out = ["# " + t.title, t.label + ":"];
    let i = 0;
    while (i < t.names.length) {
        out += "# " + t.names[i];
        out += "    .quad " + tostring(t.vals[i]);
        i += 1;
    };
    out += "";
    join(out, "\n")
};

def writer() -> Writer { { lines: [] } };

/** One line; a comment trailing an instruction moves to a line of its own above it. */
def w(wr: Writer, line: str) {
    let i = line.index_of("  #");
    if (i >= 0 && !line[:i].trim_start().starts_with("#")) {
        wr.lines += "#" + line[i + 3:];
        wr.lines += line[:i];
    } else {
        wr.lines += line;
    };
};

def text(wr: Writer, tabs: [Table]) -> str {
    let s = join(wr.lines, "\n") + "\n";
    foreach (t in tabs) { s += "\n" + block(t); };
    s
};

/** `label+N(%rip)` for an entry of a table another block of math.s owns, the
offset read out of the installed table so a table that grows fails loudly. */
def other_ref(maths: str, label: str, name: str) -> str {
    let i = maths.index_of("\n" + label + ":\n");
    if (i < 0) { die("math.s has no " + label); };
    let e = maths.index_of("\n\n", i);
    let n = 0;
    foreach (l in maths[i + 1:e].split("\n")) {
        if (l.starts_with("# ") && !l[2:].contains(" ")) {
            if (l[2:] == name) { return label + "+" + tostring(8 * n) + "(%rip)"; };
            n += 1;
        };
    };
    die(label + " has no " + name);
    ""
};

export { Table, Writer, die, src, bits, let_float, let_floats, table, ref, add, block, writer, w, text, other_ref };
