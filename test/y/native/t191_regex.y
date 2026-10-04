// std/regex.y: the dialect. Every supported construct once, and the results a
// reader would want to check, printed as one line each.
import regex;

// A string as one printable line: a newline or a tab spelled out, anything
// else below a space as \xHH, so the expected output can be read (and diffed).
def show(s: str) -> str {
    let out = "[";
    let i = 0;
    while (i < len(s)) {
        let c = byte_at(s, i);
        if (c == 32 || (c >= 33 && c < 127)) { out += chr(c); }
        else if (c == 10) { out += "\\n"; }
        else if (c == 9) { out += "\\t"; }
        else if (c == 13) { out += "\\r"; }
        else { out += "\\x" + hex2(c); };
        i = i + 1;
    };
    out + "]"
};

def hex2(v: long) -> str {
    let d = "0123456789abcdef";
    chr(d[v >> 4]) + chr(d[v & 15])
};

// search: the first match, and where it is
def line(pat: str, subj: str) -> long {
    let re = regex.compile(pat);
    if (re == none) {
        print(show(pat), " on ", show(subj), " -> does not compile");
        return 0;
    };
    let r = re!;
    let m = regex.search(r, subj);
    print(show(pat), " on ", show(subj), " -> ",
          (if (m == none) { "no match" } else { show(m!.text) + " at " + tostring(m!.start) }));
    0
};

// match (anchored at 0), full (the whole subject) and is_match, so all four
// ways of asking appear here.
def four(pat: str, subj: str) -> long {
    let re = regex.compile(pat)!;
    let m = regex.match(re, subj);
    let f = regex.full(re, subj);
    let t = (if (regex.is_match(re, subj)) { "yes" } else { "no" });
    print(show(pat), " on ", show(subj), " -> match ", (if (m == none) { "-" } else { show(m!.text) }),
          ", full ", (if (f == none) { "-" } else { show(f!.text) }), ", is_match ", t);
    0
};

// ── literals and the dot ──────────────────────────────────────────────────
line("abc", "xxabcyy");
line("abc", "ab");
line("a.c", "abc");
line("a.c", "a\nc");
line("a.c", "a\tc");
line(".", "a");
line(".", "\n");
line("x", "x");
line("\\.", "a.b");
line("\\x41\\x42", "zABz");
line("\\x{263A}", "a☺b");
line("\\x{7e}", "a~b");
line("\\0", "a\x00b");
line("\\t", "a\tb");
line("\\$\\^\\.\\*\\+\\?\\(\\)\\[\\]\\{\\}\\|", "$^.*+?()[]{}|");
line("a\\\\b", "a\\b");

// ── classes ───────────────────────────────────────────────────────────────
line("[abc]+", "xxcabz");
line("[^abc]+", "abxyz");
line("[a-z0-9_]+", "Ab_9-");
line("[-a]", "-a");
line("[a-]", "a-");
line("[]a]", "]a");
line("[]]", "]");
line("[\\]]", "]");
line("[\\-]", "-");
line("[\\d]", "5");
line("[\\dx]", "5x");
line("[a-c-e]", "b");
line("[[:digit:]]+", "x42");
line("[[:^digit:]]+", "4a2");
line("[[:alpha:][:digit:]]+", "a1-");
line("[[:space:]]+", "a \tb");
line("[^[:alnum:]]+", "ab!!cd");

// ── shorthands and boundaries ─────────────────────────────────────────────
line("\\d+", "x42y");
line("\\D+", "ab1");
line("\\w+", " a_1 ");
line("\\W+", "ab!!cd");
line("\\s+", "a \t\nb");
line("\\S+", "  ab  ");
line("\\bfoo\\b", "a foo b");
line("\\bfoo\\b", "afoob");
line("\\Bfoo", "afoob");
line("\\Bfoo", "a foo b");
line("\\b", "ab");
line("\\B", "ab");

// ── anchors ───────────────────────────────────────────────────────────────
line("^abc", "abc");
line("^abc", "xabc");
line("abc$", "abc");
line("abc$", "abcx");
line("^abc$", "abc");
line("a\\z", "a");
line("\\Aa\\z", "a");
line("(?m)^b", "a\nbc");
line("(?m)c$", "a\nbc");
line("(?m)^$", "a\n\nb");
line("^$", "");
line("(?s).+", "a\nb");
line("a.b", "a\nb");

// ── alternation, greedy, lazy ─────────────────────────────────────────────
line("a|ab", "ab");
line("ab|a", "ab");
line("a|ab|abc", "abc");
line("(a|ab)c", "abc");
line("foo|bar|baz", "xbarz");
four("a|ab", "ab");
four("a|ab", "abc");
four("ab|a", "ab");
line("a+", "aa");
line("a+?", "aa");
line("a*?", "aaa");
line("a*", "aaa");
line("a{3}", "aaaa");
line("a{3}", "aa");
line("a{2,}", "aaaa");
line("a{2,3}", "aaaa");
line("a{2,3}?", "aaaa");
line("a{0,2}", "aaa");
line("a{0}", "aaa");
line("a{,3}", "a{,3}");
line("a}", "a}");
line("<.+>", "<a><b>");
line("<.+?>", "<a><b>");
line("(ab)+", "ababab");
line("(ab)*", "abab");
line("(a|b)+c", "ababc");

// ── flags ─────────────────────────────────────────────────────────────────
line("(?i)abc", "ABC");
line("(?i)abc", "abc");
line("(?i)[a-z]+", "AbC");
line("(?i)(?:AB)+", "abAB");
line("(?i)a(?i)b", "AB");
line("(?i)(a)", "A");
line("(?i)(?-i:a)b", "Ab");
line("(?s).+", "a\nb");
line("(?im)^a$", "A\nb");

// ── lookaround ────────────────────────────────────────────────────────────
line("foo(?=bar)", "foobar");
line("foo(?!bar)", "foobar");
line("(?=bar)foo", "barfoo");
line("(?!x)", "abc");
line("foo(?<=foo)bar", "foobar");
line("(?<!x)bar", "bar");
line("(?<=a)b", "ab");
line("(?<=ab)c", "abc");
line("\\d+(?=%)", "50%");
line("(?!b)(?!c)a", "ad");
line("(?<=a|ab)c", "abc");

// ── the four that ask about one position ──────────────────────────────────
let at_re = regex.compile("\\d+")!;
print("search_at: ", regex.search_at(at_re, "ab 123", 0)!.text, " ",
      regex.search_at(at_re, "ab 123", 3)!.text, " ",
      (if (regex.search_at(at_re, "ab 123", 6) == none) { "none" } else { "some" }),
      " ", (if (regex.search_at(at_re, "ab 123", 0 - 1) == none) { "none" } else { "some" }));
print("match_at:  ", regex.match_at(at_re, "12ab", 0)!.text, " ",
      (if (regex.match_at(at_re, "ab12", 0) == none) { "none" } else { "some" }), " ",
      (if (regex.match_at(at_re, "12ab", 5) == none) { "none" } else { "some" }));
let anch = regex.compile("^\\d+")!;
print("anchored:  ", (if (regex.search(anch, "a12") == none) { "none" } else { "some" }),
      " ", regex.search_at(anch, "a12", 1), " ", (if (regex.search_at(anch, "12", 0) == none) { "none" } else { "some" }));

// ── escape ────────────────────────────────────────────────────────────────
print("escape: ", regex.escape("a.b*c d"));
print("escape: ", regex.escape("x\ty"));

// ── a pattern that does not compile ───────────────────────────────────────
// Every message, one per line: compile gives none, check says why.
line("[a", "a");
line("(ab", "ab");
line("ab)", "ab");
line("*a", "a");
line("a**", "a");
line("a*+", "a");
line("a\\", "a");
line("a\\q", "aq");
line("a{2,x}", "a");
line("a{5,2}", "a");
line("a{1,2000}", "a");
line("(?<=a+)b", "aab");
line("(?=(a))a", "a");
line("(?P<n>a)", "a");
line("(?<n>a)(?<n>b)", "ab");
line("(?<1n>a)", "a");
line("(?<>a)", "a");
line("(?q)a", "a");
line("(?i)(?-i:a)", "a");
line("[[:foo:]]", "a");
line("[z-a]", "a");
line("[a-]", "a");
line("\\x{110000}", "a");
line("\\x{ d}", "a");
line("\\x{41", "a");
line("\\xZZ", "a");
line("\\1", "a");
line("(a)\\1", "aa");

// ── the limits, each with the message that keeps the machine's memory ─────
print("1000 reps: ", regex.check("a{1000}"));
print("1001 reps: ", regex.check("a{1001}"));
print("too many instructions: ", regex.check("a{1000}a{1000}a{1000}a{1000}a{1000}"));
let groups = "";
let i = 0;
while (i < 200) { groups += "(a)"; i = i + 1; };
print("200 groups: ", regex.check(groups));
print("201 groups: ", regex.check(groups + "(a)"));
// A total, which bounds the nesting the machine stack follows
let looks = "b";
let j = 0;
while (j < 32) { looks = "(?=a)" + looks; j = j + 1; };
print("32 lookarounds: ", regex.check(looks));
print("33 lookarounds: ", regex.check("(?=a)" + looks));
print("nesting  50: ", regex.check("((((((((((a))))))))))"));
print("nesting 200: ", regex.check("(((((a)))))"));
print("nesting 201: ", regex.check(nest(201) + "a" + nest(201)));
print("none for a{1001}: ", (if (regex.compile("a{1001}") == none) { "yes" } else { "no" }));
print("blank compiles: ", (if (regex.compile("") == none) { "no" } else { "yes" }));
print("blank matches at: ", regex.search(regex.compile("")!, "abc")!.start);

// non-capturing, so this is the DEPTH limit and not the group-count one
def nest(n: long) -> str {
    let out = "";
    let i = 0;
    while (i < n) { out += "(?:"; i = i + 1; };
    out
};