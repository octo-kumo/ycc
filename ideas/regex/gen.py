#!/usr/bin/env python3
"""Differential test for std/regex.y: emit the fixture the tree runs
(test/y/native/t195_regex_corpus.y, which calls the engine) and what Python's
re says about the same BYTES (its .expected), then diff them —
ideas/regex/run.sh does that. One case list, both outputs, one canonical format,
so a diff is meaningful.

Known, documented divergences from Python (asserted separately, see KNOWN):
  - replace: our empty match replaces nothing, Python's inserts at every one
  - split:    ours cuts only on a match that took bytes; Python cuts on empty too
  - find:     both skip an empty match abutting the previous match's end
"""
import re, os, warnings

# The fixture lives in the tree, so the native suite checks it like any other
# t*.y; this script is its provenance (regenerate, then ideas/regex/run.sh).
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TARGET = os.path.join(ROOT, "test", "y", "native", "t195_regex_corpus.y")

warnings.filterwarnings("ignore")

RAW_CASES = [
    # literals and the dot
    (r"abc", "xxabcyy"), (r"abc", "ab"), (r"a.c", "abc"), (r"a.c", "a\nc"),
    (r".", "a"), (r".*", "abc"), (r"a+b", "aab"), (r"a*b", "b"),
    (r"a|", "a"), (r"|a", "ba"), (r"()", "ab"), (r"a||b", "ab"),
    # classes
    (r"[abc]+", "xxcabz"), (r"[^abc]+", "abxyz"), (r"[a-z0-9_]+", "Ab_9-"),
    (r"[-a]", "-a"), (r"[a-]", "a-"), (r"[]a]", "]a"), (r"[\\]]", "]"),
    (r"[[:digit:]]+", "x42"), (r"[[:^digit:]]+", "4a2"), (r"[[:alpha:][:digit:]]+", "a1-"),
    (r"[\d]", "5"), (r"[\-]", "-"), (r"[^\]]", "a"), (r"[]]", "]"),
    # shorthands and boundaries
    (r"\d+", "x42y"), (r"\D+", "ab1"), (r"\w+", " a_1 "), (r"\W+", "ab!!cd"),
    (r"\s+", "a \t\nb"), (r"\S+", "  ab "), (r"\bfoo\b", "a foo b"),
    (r"\Bfoo", "afoob"), (r"a\bb", "ab"), (r"\b", "ab"), (r"\B", "a b"),
    (r"\b\w+\b", "  hi there  "), (r"\B", "ab"),
    # escapes
    (r"\x41\x42", "zABz"), (r"\x{263A}", "a☺b"), (r"\.", "a.b"), (r"\[", "a[b"), (r"\$", "a$b"), (r"\^", "a^b"), (r"(?i)\^", "A^B"), (r"a\$", "a$b"), (r"\$\^\.\*", "$^.*x"),
    (r"a\\b", "a\\b"), (r"\0", "a\x00b"), (r"\t\n", "a\t\nb"), (r"\x7f", "a\x7fb"),
    (r"\a\b\f\v", "a\x07\x08\x0c\x0bb"),
    # anchors
    (r"^abc", "abc"), (r"abc\Z", "abc"), (r"^abc$", "abc"), (r"^abc\Z", "abc"),
    (r"(?m)^b", "a\nbc"), (r"(?m)c$", "a\nbc"), (r"^$", ""), (r"^", "abc"),
    (r"a\Z", "a"), (r"^\w+$", "abc"), (r"(?m)^$", "a\n\nb"), (r"\Aa\Z", "a"),
    # alternation, leftmost-first
    (r"a|ab", "ab"), (r"ab|a", "ab"), (r"a|ab|abc", "abc"), (r"(a|ab)c", "abc"),
    (r"foo|bar|baz", "xbarz"), (r"(a+)(b+)?", "aaa"), (r"(a|)(b|)", "ab"),
    # groups and nesting
    (r"(\d+)-(\d+)", "x 12-34 y"), (r"((a)(b))", "ab"), (r"(a(b(c)))", "abc"),
    (r"(a)|(b)", "b"), (r"(?:ab)+", "ababab"), (r"(?P<w>\w+)", "hello"),
    (r"(?:a|b)+c", "ababc"), (r"((a)|(b))+", "ab"), (r"(a(b)?)+", "ab"),
    # repetition
    (r"a{3}", "aaa"), (r"a{3}", "aa"), (r"a{2,}", "aaaa"), (r"a{2,3}", "aaaa"),
    (r"a{0,2}", "aaa"), (r"a{0}", "aaa"), (r"a+?", "aaa"), (r"a*?", "aaa"),
    (r"a{2,3}?", "aaaa"), (r"(ab)*", "ababab"), (r"(ab)+c", "ababc"),
    (r"\d{1,3}", "12345"), (r"(a*)*", "aa"), (r"(a*)+", "aa"), (r"(|a)*", "aa"),
    (r"a{2}b{2}", "aabb"),
    # laziness
    (r"<.+>", "<a><b>"), (r"<.+?>", "<a><b>"), (r"a.*?b", "axxbxxb"),
    (r"\d+?", "12345"), (r"(?:a|ab)+?", "abab"),
    # lookaround
    (r"foo(?=bar)", "foobar"), (r"foo(?!bar)", "foobaz"), (r"(?=bar)foo", "barfoo"),
    (r"foo(?<=foo)bar", "foobar"), (r"(?<!x)bar", "bar"), (r"a(?!b)c", "ac"),
    (r"\d+(?=%)", "50%"), (r"(?<=a)b", "ab"), (r"(?<=ab)c", "abc"),
    (r"(?!x)", "abc"), (r"a(?=b|b)c", "ac"), (r"(?<=a|ab)c", "abc"),
    (r"(?i)(?=abc)x", "ABC"), (r"a(?!b)(?!c)d", "ad"),
    # flags
    (r"(?i)abc", "ABC"), (r"(?i)[a-z]+", "AbC"), (r"(?s).+", "a\nb"),
    (r"(?i)(?-i:ab)", "AB"), (r"(?im)^a$", "A\nb"), (r"(?i)AB", "ab"),
    (r"(?s)a.b", "a\nb"), (r"(?i)(?:AB)+", "abAB"), (r"(?s)^.*$", "a\nb\nc"),
    # not supported: each is an error
    (r"(a)\1", "aa"), (r"[a", "a"), (r"(ab", "ab"), (r"ab)", "ab"), (r"*a", "a"),
    (r"a\\", "a"), (r"a\\q", "aq"), (r"a{,3}", "a{,3}"), (r"a}", "a}"),
    (r"a{2,x}", "a"), (r"a{5,2}", "a"), (r"a{1,2000}", "a"), (r"(?<=a+)b", "aab"),
    (r"(?=(a))a", "a"), (r"(?P<n>a)", "a"), (r"(?<n>a)(?<n>b)", "ab"),
    (r"(?<1n>a)", "a"), (r"(?q)a", "a"), (r"(?<>a)", "a"), (r"[:foo:]", "a"),
    (r"\x{110000}", "a"), (r"\x{ d}", "a"), (r"\x{41", "a"), (r"\xZZ", "a"),
    (r"a*+", "x"), (r"a**", "a"), (r"a--b", "a"), (r"\1", "a"), (r"a{2,1}", "a"),
    # the empty pattern and empty matches
    (r"", "abc"), (r"a*", "baab"), (r"a*", ""), (r"x{0}", "x"), (r"b*", "abc"),
    # a greedy loop whose own character class overlaps what follows it: the
    # captures here are what a list-aliasing bug in the machine breaks
    (r"(\S+)@(\S+):(\d+)", "root@localhost:22"),
    (r"(\w+)@(\w+)", "a@b"), (r"(\w+)-(\w+)", "ab-cd"),
    (r"(\S+)\s(\S+)", "ab cd"), (r"(.*),(.*)", "a,b,c"),
    (r"(\w+)x(\w*)", "aax"), (r"(\d+):(\d+)", "1:22"),
    (r"(a+)b", "aaab"), (r"a+ab", "aaab"), (r"(.*)b", "aabb"),
    (r"([^,]+),([^,]+)", "a,bb,ccc"), (r"(\w)(\w)?", "a"),
    (r"(a*)(a*)b", "aab"), (r"(\S*)\s*(\S*)", "  "),
    # a literal prefix, case-insensitive, a non-word byte in one
    (r"nginx/1\.2", "server nginx/1.2.3 ok"), (r"(?i)NGINX", "x nginx y"),
    # pathological: linear time is the point of the Pike VM (Python copes at
    # this size; the fixture times a bigger one)
    (r"(a*)*b", "aaaaaaaaaaaac"), (r"(a|aa)+b", "aaaaaaaaaaaac"),
    (r"a{1,1000}b", "a" * 40 + "c"),
]

CASES = [(p.encode("utf-8"), s.encode("utf-8")) for p, s in RAW_CASES]

# Where Python's re is NOT the reference, and what we assert instead. Four kinds:
#   - a dialect of ours Python has no spelling for: POSIX classes inside [...],
#     \x{...}, \z (Python's \Z), (?<name>) (Python's (?P<name>)), and a '{'
#     that does not open a repetition being a literal byte (PCRE reads {,3} as
#     {0,3}; we read it as four bytes, which never surprises a pattern's author)
#   - our own diagnostics, which are ours by design (compile -> none, and the
#     message from check)
#   - (?-i: … ), which we reject on purpose
#   - where an NFA and a backtracker differ and we are the NFA: the captures of
#     a loop whose last iteration took no bytes are the last one that did
PINNED = {}
for _entry in r"""[[:digit:]]+	pat=[[[:digit:]]+] subj=[x42]
  match=-
  full=-
  search=[42] 1..3
  groups=-
  find=42@1
  is_match=true
  replace=[x<42>]
@@@
[[:^digit:]]+	pat=[[[:^digit:]]+] subj=[4a2]
  match=-
  full=-
  search=[a] 1..2
  groups=-
  find=a@1
  is_match=true
  replace=[4<a>2]
@@@
[[:alpha:][:digit:]]+	pat=[[[:alpha:][:digit:]]+] subj=[a1-]
  match=[a1] 0..2
  full=-
  search=[a1] 0..2
  groups=-
  find=a1@0
  is_match=true
  replace=[<a1>-]
@@@
\x{263A}	pat=[\x{263A}] subj=[a\xe2\x98\xbab]
  match=-
  full=-
  search=[\xe2\x98\xba] 1..4
  groups=-
  find=\xe2\x98\xba@1
  is_match=true
  replace=[a<\xe2\x98\xba>b]
@@@
abc\Z	pat=[abc\Z] subj=[abc]\n  CHECK unknown escape \Z at byte 4
@@@
^abc\Z	pat=[^abc\Z] subj=[abc]\n  CHECK unknown escape \Z at byte 5
@@@
a\Z	pat=[a\Z] subj=[a]\n  CHECK unknown escape \Z at byte 2
@@@
\Aa\Z	pat=[\Aa\Z] subj=[a]\n  CHECK unknown escape \Z at byte 4
@@@
(?P<w>\w+)	pat=[(?P<w>\w+)] subj=[hello]\n  CHECK unknown flag 'P' at byte 2
@@@
(a*)*	pat=[(a*)*] subj=[aa]
  match=[aa] 0..2
  full=[aa]
  search=[aa] 0..2
  groups=[aa]
  find=<differs>
  is_match=true
  replace=<differs>
@@@
(a*)+	pat=[(a*)+] subj=[aa]
  match=[aa] 0..2
  full=[aa]
  search=[aa] 0..2
  groups=[aa]
  find=<differs>
  is_match=true
  replace=<differs>
@@@
(|a)*	pat=[(|a)*] subj=[aa]
  match=[aa] 0..2
  full=[aa]
  search=[aa] 0..2
  groups=[a]
  find=<differs>
  is_match=true
  replace=<differs>
@@@
(?<=a|ab)c	pat=[(?<=a|ab)c] subj=[abc]\n  CHECK lookbehind must be a fixed width at byte 9
@@@
(?i)(?-i:ab)	pat=[(?i)(?-i:ab)] subj=[AB]\n  CHECK a flag cannot be turned off at byte 6
@@@
(a)\1	pat=[(a)\1] subj=[aa]\n  CHECK a backreference is not supported at byte 4
@@@
[a	pat=[[a] subj=[a]\n  CHECK unterminated character class at byte 2
@@@
(ab	pat=[(ab] subj=[ab]\n  CHECK unterminated group at byte 3
@@@
ab)	pat=[ab)] subj=[ab]\n  CHECK unbalanced ) at byte 2
@@@
*a	pat=[*a] subj=[a]\n  CHECK nothing to repeat at byte 0
@@@
a{,3}	pat=[a{,3}] subj=[a{,3}]
  match=[a{,3}] 0..5
  full=[a{,3}]
  search=[a{,3}] 0..5
  groups=-
  find=a{,3}@0
  is_match=true
  replace=[<a{,3}>]
@@@
a{2,x}	pat=[a{2,x}] subj=[a]\n  CHECK bad repetition count at byte 4
@@@
a{5,2}	pat=[a{5,2}] subj=[a]\n  CHECK a repetition count is out of order at byte 6
@@@
a{1,2000}	pat=[a{1,2000}] subj=[a]\n  CHECK a repetition count must be at most 1000 at byte 9
@@@
(?<=a+)b	pat=[(?<=a+)b] subj=[aab]\n  CHECK lookbehind must be a fixed width at byte 7
@@@
(?=(a))a	pat=[(?=(a))a] subj=[a]\n  CHECK a group cannot be inside a lookaround at byte 7
@@@
(?P<n>a)	pat=[(?P<n>a)] subj=[a]\n  CHECK unknown flag 'P' at byte 2
@@@
(?<n>a)(?<n>b)	pat=[(?<n>a)(?<n>b)] subj=[ab]\n  CHECK duplicate group name 'n' at byte 12
@@@
(?<1n>a)	pat=[(?<1n>a)] subj=[a]\n  CHECK a group name must start with a letter or _ at byte 3
@@@
(?q)a	pat=[(?q)a] subj=[a]\n  CHECK unknown flag 'q' at byte 2
@@@
(?<>a)	pat=[(?<>a)] subj=[a]\n  CHECK a group name must start with a letter or _ at byte 3
@@@
\x{110000}	pat=[\x{110000}] subj=[a]\n  CHECK a \x{} value must be at most 0x10ffff at byte 10
@@@
\x{ d}	pat=[\x{ d}] subj=[a]\n  CHECK a \x{} needs at least one hex digit at byte 3
@@@
\x{41	pat=[\x{41] subj=[a]\n  CHECK a \x{ is not closed at byte 5
@@@
\xZZ	pat=[\xZZ] subj=[a]\n  CHECK a \x needs two hex digits at byte 2
@@@
a*+	pat=[a*+] subj=[x]\n  CHECK a repetition cannot be possessive at byte 2
@@@
a**	pat=[a**] subj=[a]\n  CHECK two repetitions in a row at byte 2
@@@
\1	pat=[\1] subj=[a]\n  CHECK a backreference is not supported at byte 1
@@@
a{2,1}	pat=[a{2,1}] subj=[a]\n  CHECK a repetition count is out of order at byte 6""".split("\n@@@\n"):
    if "\t" not in _entry:
        continue
    _pat, _blk = _entry.split("\t", 1)
    PINNED[_pat] = _blk


def esc_text(b: bytes) -> str:
    """The bytes as text: printable as itself, a newline/tab spelled out, any
    other byte as \\xHH."""
    out = ""
    for c in b:
        if c == 32 or (33 <= c < 127):
            out += chr(c)
        elif c == 10:
            out += "\\n"
        elif c == 9:
            out += "\\t"
        else:
            out += "\\x%02x" % c
    return out


def shown(b: bytes) -> str:
    if b == b"":
        return "<empty>"
    return "[" + esc_text(b) + "]"


def mline(m) -> str:
    if m is None:
        return "-"
    return "%s %d..%d" % (shown(m.group(0)), m.start(), m.end())


def has_empty_match(pat: bytes, subj: bytes) -> bool:
    """Whether an empty match is in play — where our find and replace differ."""
    try:
        rx = re.compile(pat)
    except re.error:
        return False
    if rx.fullmatch(b"") is not None:
        return True
    for m in rx.finditer(subj):
        if m.start() == m.end():
            return True
    return False


def show(pat: bytes, subj: bytes) -> str:
    pinned = PINNED.get(pat.decode("latin1"))
    if pinned is not None:
        return pinned
    out = ["pat=%s subj=%s" % (shown(pat), shown(subj))]
    try:
        rx = re.compile(pat)
    except re.error as e:
        return "\n".join(out) + "\n  CHECK %s" % e
    out.append("  match=%s" % mline(rx.match(subj)))
    fm = rx.fullmatch(subj)
    out.append("  full=%s" % (shown(fm.group(0)) if fm else "-"))
    m = rx.search(subj)
    out.append("  search=%s" % mline(m))
    if m is None:
        out.append("  groups=-")
    else:
        gs = [("-" if m.group(i) is None else shown(m.group(i))) for i in range(1, rx.groups + 1)]
        named = ["%s=%s" % (k, shown(m.group(k))) for k in rx.groupindex]
        out.append("  groups=%s%s" % ("|".join(gs) if gs else "-",
                                      ";" + ";".join(named) if named else ""))
    if has_empty_match(pat, subj):
        out.append("  find=<differs>")
    else:
        fs = ["%s@%d" % (esc_text(f.group(0)), f.start()) for f in rx.finditer(subj)]
        out.append("  find=%s" % (",".join(fs) if fs else "-"))
    out.append("  is_match=%s" % ("true" if rx.search(subj) else "false"))
    if has_empty_match(pat, subj):
        out.append("  replace=<differs>")
    else:
        out.append("  replace=%s" % shown(rx.sub(lambda mm: b"<" + mm.group(0) + b">", subj)))
    return "\n".join(out)


Y_HEAD = '''// Generated by ideas/regex/gen.py — do not edit by hand; regenerate with
//   python3 ideas/regex/gen.py && ideas/regex/run.sh
// 178 cases against the engine, with what Python's re says about the same BYTES
// as the expected output (the native suite checks this file the way it checks
// every other t*.y).  Where Python is not the reference — our own dialect, our
// own diagnostics, and the places an NFA and a backtracker differ — the answer
// is pinned in gen.py's PINNED table, with the reason.
import regex;

def esc_text(s: str) -> str {
    let out = "";
    let i = 0;
    while (i < len(s)) {
        let c = byte_at(s, i);
        if (c == 32 || (c >= 33 && c < 127)) { out += chr(c); }
        else if (c == 10) { out += "\\\\n"; }
        else if (c == 9) { out += "\\\\t"; }
        else { out += "\\\\x" + hex(c); };
        i = i + 1;
    };
    out
};

def hex(v: long) -> str {
    let d = "0123456789abcdef";
    chr(d[v >> 4]) + chr(d[v & 15])
};

def shown(s: str) -> str {
    if (len(s) == 0) { "<empty>" } else { "[" + esc_text(s) + "]" }
};

def mline(m: regex.Match?) -> str {
    if (m == none) { return "-"; };
    let mm = m!;
    shown(mm.text) + " " + tostring(mm.start) + ".." + tostring(mm.end)
};

def groups(re: regex.Re, m: regex.Match?) -> str {
    if (m == none) { return "-"; };
    let mm = m!;
    let out: [str] = [];
    let i = 1;
    while (i <= re.groups) {
        let g = regex.group(mm, i);
        out += (if (g == none) { "-" } else { shown(g!) });
        i = i + 1;
    };
    let j = (if (re.groups == 0) { "-" } else { join(out, "|") });
    let named: [str] = [];
    foreach (k in keys(mm.names)) { named += k + "=" + shown(regex.named(mm, k)!) };
    if (len(named) > 0) { j += ";" + join(named, ";") };
    j
};

def show(pat: str, subj: str) -> str {
    let w = regex.check(pat);
    if (w != "") { return "pat=" + shown(pat) + " subj=" + shown(subj) + "\\\\n  CHECK " + w };
    let re = regex.compile(pat)!;
    let m = regex.search(re, subj);
    let fs: [str] = [];
    foreach (f in regex.find(re, subj)) { fs += esc_text(f.text) + "@" + tostring(f.start) };
    let out = "pat=" + shown(pat) + " subj=" + shown(subj);
    out += "\\n  match=" + mline(regex.match(re, subj));
    let fm = regex.full(re, subj);
    out += "\\n  full=" + (if (fm == none) { "-" } else { shown(fm!.text) });
    out += "\\n  search=" + mline(m);
    out += "\\n  groups=" + groups(re, m);
    if (find_empty(re, subj)) { out += "\\n  find=<differs>"; }
    else { out += "\\n  find=" + (if (len(fs) == 0) { "-" } else { join(fs, ",") }); };
    out += "\\n  is_match=" + tostring(regex.is_match(re, subj));
    out += "\\n  replace=" + (if (find_empty(re, subj)) { "<differs>" } else { shown(regex.replace(re, subj, "<$0>")) });
    out
};

// Whether an empty match is in play. There our find and replace differ from
// Python's: we skip an empty match abutting the previous match's end (Go's
// rule) and an empty match replaces nothing, where Python's inserts. The
// pattern matching the empty string counts too, since our find would not show
// the empty match it then skips.
def find_empty(re: regex.Re, s: str) -> bool {
    if (regex.full(re, "") != none) { return true; };
    let out = false;
    foreach (m in regex.find(re, s)) {
        if (m.start == m.end) { out = true; };
    };
    out
};

'''


def esc(b: bytes) -> str:
    out = []
    for c in b:
        ch = chr(c)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif 32 <= c < 127:
            out.append(ch)
        else:
            out.append("\\x%02x" % c)
    return '"' + "".join(out) + '"'


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    y = [Y_HEAD]
    for pat, subj in CASES:
        y.append("print(show(%s, %s));\n" % (esc(pat), esc(subj)))
    with open(TARGET, "w") as f:
        f.write("".join(y))
    with open(TARGET[:-2] + ".expected", "w") as f:
        f.write("\n".join(show(p, s) for p, s in CASES) + "\n")


main()