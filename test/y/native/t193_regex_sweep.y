// std/regex.y: find, split, replace and replace_with — the four that walk a
// whole subject, including the empty-match rules, which are the parts a reader
// is most likely to be surprised by.
import regex;

def show(s: str) -> str {
    let out = "[";
    let i = 0;
    while (i < len(s)) {
        let c = byte_at(s, i);
        if (c == 32 || (c >= 33 && c < 127)) { out += chr(c); }
        else if (c == 10) { out += "\\n"; }
        else if (c == 9) { out += "\\t"; }
        else { out += "\\x" + hex2(c); };
        i = i + 1;
    };
    out + "]"
};

def hex2(v: long) -> str {
    let d = "0123456789abcdef";
    chr(d[v >> 4]) + chr(d[v & 15])
};

def parts(xs: [str]) -> str {
    let out: [str] = [];
    foreach (x in xs) { out += show(x); };
    join(out, " ")
};

def texts(ms: [regex.Match]) -> str {
    let out: [str] = [];
    foreach (m in ms) { out += show(m.text) + "@" + tostring(m.start); };
    if (len(out) == 0) { "-" } else { join(out, ",") }
};

def find(pat: str, subj: str) -> long {
    print("find    ", show(pat), " on ", show(subj), " -> ", texts(regex.find(regex.compile(pat)!, subj)));
    0
};

def find2(pat: str, subj: str, limit: long) -> long {
    print("find(", tostring(limit), ") ", show(pat), " on ", show(subj), " -> ",
          texts(regex.find(regex.compile(pat)!, subj, limit)));
    0
};

def split(pat: str, subj: str) -> long {
    print("split   ", show(pat), " on ", show(subj), " -> ", parts(regex.split(regex.compile(pat)!, subj)));
    0
};

def replace(pat: str, subj: str, rep: str) -> long {
    print("replace ", show(pat), " on ", show(subj), " -> ", show(regex.replace(regex.compile(pat)!, subj, rep)));
    0
};

// ── find: left to right, non-overlapping ──────────────────────────────────
find("a", "banana");
find("an", "banana");
find("ana", "banana");
find2("ana", "banana", 1);
find2("ana", "banana", 2);
find("z", "banana");
find("\\d+", "a1 b22 c333");
find("(\\w)(\\d)", "a1 b2");
find("^\\d", "12 34");
find("(?m)^\\d", "12\n34");
find("\\b\\w+\\b", "  hi there  ");

// ── find and empty matches ────────────────────────────────────────────────
// An empty match abutting the previous match's end is skipped (Go's rule), and
// the scan then moves on a byte — so a* over "baab" gives "", "aa", "".
find("a*", "baab");
find("a*", "");
find(".*", "abc");
find("x*", "abc");
find("()", "ab");
find("|a", "ba");
find("a|ab", "ab ab");
find("\\b", "ab");
find("(a*)*", "aa");
find("(|a)*", "aa");

// ── split: only a match that took bytes cuts ──────────────────────────────
split(",", "a,b,,c");
split(",", "a,b,");
split(",", ",a");
split(",", "");
split(",", "abc");
split("\\s+", "a  b\tc\n");
split("\\d+", "ab12cd345ef");
split("[;,]", "a;b,c");
split("a*", "baab");                       // a match of no bytes splits nothing
split("x", "abc");                         // and one trailing piece goes, as str.split
split("^\\s+|\\s+$", "  a b  ");
split("(?i)B", "aBcB");

// ── replace ───────────────────────────────────────────────────────────────
replace(",", "a,b,c", ";");
replace("\\s+", "a  b\tc", "_");
replace("(\\w+)@(\\w+)", "root@host, a@b", "$2/$1");
replace("(\\d{4})-(\\d{2})-(\\d{2})", "2026-10-04", "$3.$2.$1");
replace("x*", "abc", "-");                 // an empty match replaces nothing
replace("a", "aaa", "");                   // with an empty replacement
replace("(?i)abc", "xABCx", "[");
replace("^\\d+", "12ab", "#");
replace("(?m)^\\d+", "1\n2", "#");
replace("\\$", "a$b", "!");
replace("(a)|(b)", "ab", "[$1$2]");        // a group that took no part is ""

// ── replace_with ──────────────────────────────────────────────────────────
let upper = def (m: regex.Match) -> str { m.text.upper() };
print("with    ", regex.replace_with(regex.compile("\\w+")!, "hi there", upper));
let shape = def (m: regex.Match) -> str {
    if (len(m.text) == 1) { return m.text; };
    m.text[0:1] + tostring(len(m.text) - 2) + m.text[len(m.text) - 1:len(m.text)]
};
print("shape   ", regex.replace_with(regex.compile("\\w+")!, "a bb cccc", shape));
print("shape-  ", regex.replace_with(regex.compile("x*")!, "abc", shape));

// ── a log line, the shape these are for ───────────────────────────────────
let line = regex.compile("^(?<host>\\S+) \\S+ \\S+ \\[(?<ts>[^\\]]+)\\] \"(?<verb>\\S+) (?<path>\\S+) (?<code>\\d{3}) (?<bytes>\\d+|-)\"")!;
foreach (m in regex.find(line, "web01 - - [04/Oct/2026:12:00:00 +0000] \"GET /a/b?q=1 200 512\"\nweb02 - - [04/Oct/2026:12:00:01 +0000] \"POST /login 302 -\"")) {
    print("  ", regex.named(m, "host")!, " ", regex.named(m, "verb")!, " ",
          regex.named(m, "path")!, " ", regex.group(m, 5)!, " bytes=", regex.group(m, 6)!);
};