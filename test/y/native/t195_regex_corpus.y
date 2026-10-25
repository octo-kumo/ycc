// Generated once from Python's re; a checked-in fixture now, edited by hand
// like any other.
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
        else if (c == 10) { out += "\\n"; }
        else if (c == 9) { out += "\\t"; }
        else { out += "\\x" + hex(c); };
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
    if (w != "") { return "pat=" + shown(pat) + " subj=" + shown(subj) + "\\n  CHECK " + w };
    let re = regex.compile(pat)!;
    let m = regex.search(re, subj);
    let fs: [str] = [];
    foreach (f in regex.find(re, subj)) { fs += esc_text(f.text) + "@" + tostring(f.start) };
    let out = "pat=" + shown(pat) + " subj=" + shown(subj);
    out += "\n  match=" + mline(regex.match(re, subj));
    let fm = regex.full(re, subj);
    out += "\n  full=" + (if (fm == none) { "-" } else { shown(fm!.text) });
    out += "\n  search=" + mline(m);
    out += "\n  groups=" + groups(re, m);
    if (find_empty(re, subj)) { out += "\n  find=<differs>"; }
    else { out += "\n  find=" + (if (len(fs) == 0) { "-" } else { join(fs, ",") }); };
    out += "\n  is_match=" + tostring(regex.is_match(re, subj));
    out += "\n  replace=" + (if (find_empty(re, subj)) { "<differs>" } else { shown(regex.replace(re, subj, "<$0>")) });
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

print(show("abc", "xxabcyy"));
print(show("abc", "ab"));
print(show("a.c", "abc"));
print(show("a.c", "a\nc"));
print(show(".", "a"));
print(show(".*", "abc"));
print(show("a+b", "aab"));
print(show("a*b", "b"));
print(show("a|", "a"));
print(show("|a", "ba"));
print(show("()", "ab"));
print(show("a||b", "ab"));
print(show("[abc]+", "xxcabz"));
print(show("[^abc]+", "abxyz"));
print(show("[a-z0-9_]+", "Ab_9-"));
print(show("[-a]", "-a"));
print(show("[a-]", "a-"));
print(show("[]a]", "]a"));
print(show("[\\\\]]", "]"));
print(show("[[:digit:]]+", "x42"));
print(show("[[:^digit:]]+", "4a2"));
print(show("[[:alpha:][:digit:]]+", "a1-"));
print(show("[\\d]", "5"));
print(show("[\\-]", "-"));
print(show("[^\\]]", "a"));
print(show("[]]", "]"));
print(show("\\d+", "x42y"));
print(show("\\D+", "ab1"));
print(show("\\w+", " a_1 "));
print(show("\\W+", "ab!!cd"));
print(show("\\s+", "a \t\nb"));
print(show("\\S+", "  ab "));
print(show("\\bfoo\\b", "a foo b"));
print(show("\\Bfoo", "afoob"));
print(show("a\\bb", "ab"));
print(show("\\b", "ab"));
print(show("\\B", "a b"));
print(show("\\b\\w+\\b", "  hi there  "));
print(show("\\B", "ab"));
print(show("\\x41\\x42", "zABz"));
print(show("\\x{263A}", "a\xe2\x98\xbab"));
print(show("\\.", "a.b"));
print(show("\\[", "a[b"));
print(show("\\$", "a$b"));
print(show("\\^", "a^b"));
print(show("(?i)\\^", "A^B"));
print(show("a\\$", "a$b"));
print(show("\\$\\^\\.\\*", "$^.*x"));
print(show("a\\\\b", "a\\b"));
print(show("\\0", "a\x00b"));
print(show("\\t\\n", "a\t\nb"));
print(show("\\x7f", "a\x7fb"));
print(show("\\a\\b\\f\\v", "a\x07\x08\x0c\x0bb"));
print(show("^abc", "abc"));
print(show("abc\\Z", "abc"));
print(show("^abc$", "abc"));
print(show("^abc\\Z", "abc"));
print(show("(?m)^b", "a\nbc"));
print(show("(?m)c$", "a\nbc"));
print(show("^$", ""));
print(show("^", "abc"));
print(show("a\\Z", "a"));
print(show("^\\w+$", "abc"));
print(show("(?m)^$", "a\n\nb"));
print(show("\\Aa\\Z", "a"));
print(show("a|ab", "ab"));
print(show("ab|a", "ab"));
print(show("a|ab|abc", "abc"));
print(show("(a|ab)c", "abc"));
print(show("foo|bar|baz", "xbarz"));
print(show("(a+)(b+)?", "aaa"));
print(show("(a|)(b|)", "ab"));
print(show("(\\d+)-(\\d+)", "x 12-34 y"));
print(show("((a)(b))", "ab"));
print(show("(a(b(c)))", "abc"));
print(show("(a)|(b)", "b"));
print(show("(?:ab)+", "ababab"));
print(show("(?P<w>\\w+)", "hello"));
print(show("(?:a|b)+c", "ababc"));
print(show("((a)|(b))+", "ab"));
print(show("(a(b)?)+", "ab"));
print(show("a{3}", "aaa"));
print(show("a{3}", "aa"));
print(show("a{2,}", "aaaa"));
print(show("a{2,3}", "aaaa"));
print(show("a{0,2}", "aaa"));
print(show("a{0}", "aaa"));
print(show("a+?", "aaa"));
print(show("a*?", "aaa"));
print(show("a{2,3}?", "aaaa"));
print(show("(ab)*", "ababab"));
print(show("(ab)+c", "ababc"));
print(show("\\d{1,3}", "12345"));
print(show("(a*)*", "aa"));
print(show("(a*)+", "aa"));
print(show("(|a)*", "aa"));
print(show("a{2}b{2}", "aabb"));
print(show("<.+>", "<a><b>"));
print(show("<.+?>", "<a><b>"));
print(show("a.*?b", "axxbxxb"));
print(show("\\d+?", "12345"));
print(show("(?:a|ab)+?", "abab"));
print(show("foo(?=bar)", "foobar"));
print(show("foo(?!bar)", "foobaz"));
print(show("(?=bar)foo", "barfoo"));
print(show("foo(?<=foo)bar", "foobar"));
print(show("(?<!x)bar", "bar"));
print(show("a(?!b)c", "ac"));
print(show("\\d+(?=%)", "50%"));
print(show("(?<=a)b", "ab"));
print(show("(?<=ab)c", "abc"));
print(show("(?!x)", "abc"));
print(show("a(?=b|b)c", "ac"));
print(show("(?<=a|ab)c", "abc"));
print(show("(?i)(?=abc)x", "ABC"));
print(show("a(?!b)(?!c)d", "ad"));
print(show("(?i)abc", "ABC"));
print(show("(?i)[a-z]+", "AbC"));
print(show("(?s).+", "a\nb"));
print(show("(?i)(?-i:ab)", "AB"));
print(show("(?im)^a$", "A\nb"));
print(show("(?i)AB", "ab"));
print(show("(?s)a.b", "a\nb"));
print(show("(?i)(?:AB)+", "abAB"));
print(show("(?s)^.*$", "a\nb\nc"));
print(show("(a)\\1", "aa"));
print(show("[a", "a"));
print(show("(ab", "ab"));
print(show("ab)", "ab"));
print(show("*a", "a"));
print(show("a\\\\", "a"));
print(show("a\\\\q", "aq"));
print(show("a{,3}", "a{,3}"));
print(show("a}", "a}"));
print(show("a{2,x}", "a"));
print(show("a{5,2}", "a"));
print(show("a{1,2000}", "a"));
print(show("(?<=a+)b", "aab"));
print(show("(?=(a))a", "a"));
print(show("(?P<n>a)", "a"));
print(show("(?<n>a)(?<n>b)", "ab"));
print(show("(?<1n>a)", "a"));
print(show("(?q)a", "a"));
print(show("(?<>a)", "a"));
print(show("[:foo:]", "a"));
print(show("\\x{110000}", "a"));
print(show("\\x{ d}", "a"));
print(show("\\x{41", "a"));
print(show("\\xZZ", "a"));
print(show("a*+", "x"));
print(show("a**", "a"));
print(show("a--b", "a"));
print(show("\\1", "a"));
print(show("a{2,1}", "a"));
print(show("", "abc"));
print(show("a*", "baab"));
print(show("a*", ""));
print(show("x{0}", "x"));
print(show("b*", "abc"));
print(show("(\\S+)@(\\S+):(\\d+)", "root@localhost:22"));
print(show("(\\w+)@(\\w+)", "a@b"));
print(show("(\\w+)-(\\w+)", "ab-cd"));
print(show("(\\S+)\\s(\\S+)", "ab cd"));
print(show("(.*),(.*)", "a,b,c"));
print(show("(\\w+)x(\\w*)", "aax"));
print(show("(\\d+):(\\d+)", "1:22"));
print(show("(a+)b", "aaab"));
print(show("a+ab", "aaab"));
print(show("(.*)b", "aabb"));
print(show("([^,]+),([^,]+)", "a,bb,ccc"));
print(show("(\\w)(\\w)?", "a"));
print(show("(a*)(a*)b", "aab"));
print(show("(\\S*)\\s*(\\S*)", "  "));
print(show("nginx/1\\.2", "server nginx/1.2.3 ok"));
print(show("(?i)NGINX", "x nginx y"));
print(show("(a*)*b", "aaaaaaaaaaaac"));
print(show("(a|aa)+b", "aaaaaaaaaaaac"));
print(show("a{1,1000}b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac"));
