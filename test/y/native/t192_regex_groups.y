// std/regex.y: capture groups — numbering, names, offsets, and the difference
// between a group that matched nothing and one that took no part.
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

// every group of a match, as text (or "-" for one that took no part)
def groups(m: regex.Match) -> str {
    let out: [str] = [];
    let i = 1;
    while (i <= len(m.caps) / 2 - 1) {
        let g = regex.group(m, i);
        out += (if (g == none) { "-" } else { show(g!) });
        i = i + 1;
    };
    join(out, " ")
};

def spans(m: regex.Match) -> str {
    let out: [str] = [];
    let i = 1;
    while (i <= len(m.caps) / 2 - 1) {
        out += tostring(regex.start(m, i)) + ".." + tostring(regex.end(m, i));
        i = i + 1;
    };
    join(out, " ")
};

def one(pat: str, subj: str) -> long {
    let re = regex.compile(pat)!;
    let m = regex.search(re, subj);
    if (m == none) {
        print(show(pat), " on ", show(subj), " -> no match");
    } else {
        print(show(pat), " on ", show(subj), " -> ", show(m!.text), " at ", tostring(m!.start),
              " | groups ", groups(m!), " | spans ", spans(m!), " | caps ", join(m!.caps, ","));
    };
    0
};

// ── numbering, nesting ────────────────────────────────────────────────────
one("(a)", "a");
one("(a)(b)", "ab");
one("((a)(b))", "ab");
one("(a(b(c)))", "abc");
one("(a)(b)(c)", "abc");
one("(?:a)(b)", "ab");                      // (?: … ) takes no number
one("(a)(?:b)(c)", "abc");

// ── names ─────────────────────────────────────────────────────────────────
one("(?<year>\\d{4})-(?<month>\\d{2})", "2026-10");
one("(?<year>\\d{4})-(?<month>\\d{2})-(?<day>\\d{2})", "2026-10-04");

let named = regex.compile("(?<host>\\S+)@(\\S+):(?<port>\\d+)")!;
let m = regex.search(named, "root@localhost:22")!;
print("names: ", keys(m.names));
print("by name: ", regex.named(m, "host")!, " ", regex.group(m, 2)!, " ", regex.named(m, "port")!);
print("no such name: ", (if (regex.named(m, "nope") == none) { "none" } else { "some" }));
print("numbered from a name: ", regex.group(m, m.names["host"]!));
print("underscore name: ", regex.named(regex.search(regex.compile("(?<_x>a)")!, "za")!, "_x")!);

// ── took no part, or matched nothing ──────────────────────────────────────
one("(a)|(b)", "b");                          // group 1 took no part
one("(a)?b", "b");                            // ditto, through a '?'
one("a()b", "ab");                            // matched nothing
one("(x)?(y)", "y");

// ── a group repeated: the last iteration's captures ───────────────────────
one("(?:(a)|(b))+", "ab");
one("(a)|(b)", "a");
one("(\\d)(\\d)?", "7");

// ── caps is public: offsets without a call ────────────────────────────────
let two = regex.compile("(\\d+)-(\\d+)")!;
let t = regex.search(two, "x 12-34 y")!;
print("whole: ", t.start, "..", t.end, " caps ", join(t.caps, ","));
print("caps[2] is group 1 start: ", t.caps[2], " and caps[5] group 2 end: ", t.caps[5]);
print("accessors agree: ", regex.start(t, 1), " ", regex.end(t, 1), " ", regex.start(t, 2), " ", regex.end(t, 2));
print("group 0 is the whole match: ", regex.group(t, 0)!);

// ── what the accessors say about a group that took no part ────────────────
let opt = regex.compile("(a)|(b)")!;
let om = regex.search(opt, "b")!;
print("group 1: ", (if (regex.group(om, 1) == none) { "none" } else { "some" }),
      " start ", regex.start(om, 1), " end ", regex.end(om, 1));
print("group 2: ", (if (regex.group(om, 2) == none) { "none" } else { "some" }),
      " start ", regex.start(om, 2), " end ", regex.end(om, 2));

// ── replacement templates over the groups ─────────────────────────────────
let date = regex.compile("(?<y>\\d{4})-(?<m>\\d{2})-(?<d>\\d{2})")!;
let text = "on 2026-10-04 and 1999-12-31";
print("named:   ", regex.replace(date, text, "${d}/${m}/${y}"));
print("mixed:   ", regex.replace(date, text, "$2-$1"));
print("whole:   ", regex.replace(date, text, "[$0]"));
print("escaped: ", regex.replace(date, text, "$$1"));
print("unknown name stays: ", regex.replace(date, text, "$9 and ${nope}"));
print("function: ", regex.replace_with(date, text, def (x: regex.Match) -> str {
    let y = regex.named(x, "y")!;
    tostring(tolong(y)! + 1) + "/" + regex.named(x, "m")!
}));

// ── find over a subject, group by group ───────────────────────────────────
let kv = regex.compile("(\\w+)=(\\w+)")!;
foreach (hit in regex.find(kv, "a=1 bb=22 ccc=333")) {
    print("  ", hit.text, " -> ", regex.group(hit, 1)!, " is ", regex.group(hit, 2)!, " at ", hit.start);
};

// ── a group count and names are the pattern's, not the match's ────────────
print("groups: ", two.groups, " ", named.groups);
print("names: ", keys(two.names));