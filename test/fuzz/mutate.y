// mutate.y — the fuzzer's input generator (driven by fuzz.sh).
//   mutate SEED OTHER RNG OUT
// Reads two corpus programs, applies 1-4 random edits to SEED and writes
// the result to OUT: delete, duplicate or truncate a span, splice in a
// span of OTHER, insert a token of the language (or a hostile literal, a
// stray byte, a run of nesting). The same RNG always gives the same
// output, so a finding is reproducible from its seed alone.

import fs;

const TOKENS = ["def", "let", "const", "if", "else", "while", "for",
    "foreach", "in", "return", "match", "import", "export", "type", "self",
    "none", "true", "false", "{", "}", "(", ")", "[", "]", ";", ",", ":",
    "->", "=>", "=", "==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/",
    "%", "+=", "-=", "*=", "/=", "%=", "++", "--", "&&", "||", "!", "&",
    ".", "..", "?", "|", "^", "~", "<<", ">>", ">>>", "&=", "|=", "^=",
    "<<=", ">>=", ">>>=", "~x", "x & 1", "1 << 63", "-1 >>> 1",
    "@", "#", "$", "`", "\\", "\"", "'",
    "b\"", "//", "/*", "*/", "\n", " ", "\t", "long", "int", "str", "bool",
    "byte", "float", "[long]", "[byte; 4]", "[[str]]", "{ a: long }",
    "{str => long}", "long?", "*long", "() -> long", "(long) -> str", "x",
    "y", "f", "_", "a.b", "a[0]", "f(1)", "x!", "&x", "*p", "typeof(x)",
    "len(x)", "0", "1", "-1", "0x", "0b", "1_000", "1e5", "1.5", ".5", "5.",
    "def(a: long) -> long { a }", "match x { _ => 0 }", "return;",
    "{ k: 1, ...r }", "[0; 3]", "b\"\\xff\"", "'\\n'", "\"\\x41\""];

const EXTREMES = ["9223372036854775807", "9223372036854775808",
    "-9223372036854775808", "0x7fffffffffffffff", "0xffffffffffffffffff",
    "0b", "1e308", "1e999", "1e-999", "0.0", "-0.0",
    "99999999999999999999999999", "[0; 9223372036854775807]",
    "\"unterminated", "'", "\"\\", "/* unterminated"];

let rng: [long] = [0];

// 0 <= result < n (n > 0): a 64-bit LCG, high bits.
def rand(n: long) -> long {
    rng[0] = rng[0] * 6364136223846793005 + 1442695040888963407;
    let r = (rng[0] / 65536) % n;
    if (r < 0) { r + n } else { r }
};

// [i, j) with 0 <= i <= j <= len(s), at most `most` long
def span(s: str, most: long) -> [long] {
    let i = rand(len(s) + 1);
    let room = len(s) - i;
    if (room > most) { room = most; };
    [i, i + rand(room + 1)]
};

def nest(s: str, at: long) -> str {
    let opens = ["(", "[", "{", "-", "!", "&", "*"];
    let closes = [")", "]", "}", "", "", "", ""];
    let k = rand(len(opens));
    let depth = 1 + rand(300);
    let pre = "";
    let post = "";
    foreach (d in range(depth)) {
        pre += opens[k];
        post += closes[k];
    };
    s[:at] + pre + "1" + post + s[at:]
};

def mutate_once(s: str, other: str) -> str {
    let what = rand(9);
    let p = span(s, 40);
    if (what == 0) {
        s[:p[0]] + s[p[1]:]
    } else if (what == 1) {
        s[:p[1]] + s[p[0]:p[1]] + s[p[1]:]
    } else if (what == 2) {
        let q = span(other, 200);
        s[:p[0]] + other[q[0]:q[1]] + s[p[0]:]
    } else if (what == 3) {
        s[:p[0]]
    } else if (what == 4) {
        s[:p[0]] + EXTREMES[rand(len(EXTREMES))] + s[p[0]:]
    } else if (what == 5) {
        s[:p[0]] + chr(rand(256)) + s[p[0]:]
    } else if (what == 6) {
        nest(s, p[0])
    } else {
        s[:p[0]] + " " + TOKENS[rand(len(TOKENS))] + " " + s[p[0]:]
    }
};

def read_or_empty(path: str) -> str {
    let s = fs.read_file(path);
    if (s == none) { "" } else { s! }
};

let args = argv();
if (len(args) != 5) {
    eputs("usage: mutate SEED OTHER RNG OUT\n");
    exit(2);
};
rng[0] = tolong(args[3])!;
let s = read_or_empty(args[1]);
let other = read_or_empty(args[2]);
foreach (m in range(1 + rand(4))) {
    s = mutate_once(s, other);
};
if (!fs.write_file(args[4], s)) {
    eputs("mutate: cannot write " + args[4] + "\n");
    exit(1);
};
