// wxfmt.y -- integer unit conversion and column formatting.
//
// Every number this example reports is a `long`. There is no float -> long
// conversion and no cast syntax (ORCHESTRATOR.md 2.4a), and no rounding
// mode to borrow, so the arithmetic is done in integers at a finer scale
// and rounded once, explicitly, by round_div. That is the whole reason
// this file exists.
//
// ── the rounding rule, once, in one place ──────────────────────────────
//
// round_div(n, d) with d > 0 rounds to NEAREST, ties AWAY FROM ZERO:
//
//   -7 / 2  -> -4      7 / 2 -> 4      3 / 2 -> 2
//
// It is written as (2n + d) / (2d) rather than (n + d/2) / d so that it
// is exact for an exact division: n = k*d gives k + 1/2, which truncates
// back to k instead of creeping up to k+1. The identity that makes it work
// is that integer division truncates toward zero in Y, exactly as in C, so
// the negative arm only has to flip the sign of an already-positive
// quotient. Overflow: 2n must fit, which it does for every temperature and
// wind speed on Earth.

def round_div(n: long, d: long) -> long {
    if (n >= 0) { (2 * n + d) / (2 * d) } else { 0 - ((0 - 2 * n + d) / (2 * d)) }
};

// |n|, because `abs` is not a builtin (there are no math functions at all).
def magnitude(v: long) -> long { v < 0 ? 0 - v : v };

// ── Celsius -> Fahrenheit ───────────────────────────────────────────────
//
// F = C * 9/5 + 32. Done in tenths of a degree so the fraction survives:
//   f10 = c * 18 + 320        (that is exactly 10 * F)
// then one rounding step. Integers in, integers out, no float anywhere.
//
// The two scales coincide at -40 C == -40 F, and that is not a rounding
// accident: f10 = -400 divides by 10 with no remainder, so -40 maps to
// itself exactly. selftest asserts it, because a converter that is off by
// one at the one temperature where the answer is knowable by inspection is
// the classic sign of a wrong constant.
//
// There is no exact half-way case reachable from an integer Celsius value,
// and that is worth knowing rather than assuming: a tie needs
// (c*18 + 320) = 5 (mod 10), i.e. 8c = 5 (mod 10), and 8c is even. So the
// tie rule above is never exercised by real data -- it is there for the
// general case, and the rounding that IS exercised is the ordinary one
// (37 C -> 986 tenths -> 99 F, not the 98 a truncating converter gives).
def c_to_f(c: long) -> long { round_div(c * 18 + 320, 10) };

// ── km/h -> mph, in tenths ──────────────────────────────────────────────
//
// 1 mph = 1.609344 km/h exactly, so mph*10 = kmh * 10000000 / 1609344. The
// integer form is exact rational arithmetic up to the single rounding step;
// scaling by 10^7 first is what keeps it from losing the fraction at 24.
def kmh_to_mph10(k: long) -> long { round_div(k * 10000000, 1609344) };

// ── degrees of latitude/longitude ───────────────────────────────────────
//
// Held as hundred-thousandths of a degree (1e-5 deg is about 11 m) so that
// a coordinate is a long and never a float. 64.14660 N is 6414660.
def deg(v: long) -> str {
    let a = v < 0 ? 0 - v : v;
    let s = tostring(a / 100000) + "." + pad0(a % 100000, 5);
    if (v < 0) { "-" + s } else { s }
};

// ── zero-padded decimals ────────────────────────────────────────────────
def pad0(v: long, n: long) -> str {
    let s = tostring(v);
    while (s.length < n) { s = "0" + s };
    s
};

// ── display width in a UTF-8 string ─────────────────────────────────────
//
// Columns are aligned by BYTES anywhere else, which is wrong as soon as a
// glyph is not ASCII: "°" is two bytes and a snowflake is three, so a
// byte-padded table drifts. dwidth counts the bytes that are not
// continuation bytes, which for well-formed UTF-8 is the number of
// codepoints -- the number of terminal cells a glyph here occupies.
def cont(c: long) -> bool { (c & 192) == 128 };

def dwidth(s: str) -> long {
    let w = 0;
    let i = 0;
    while (i < s.length) {
        if (!cont(ord(s[i:i + 1]))) { w = w + 1 };
        i = i + 1;
    };
    w
};

def rpad(s: str, n: long) -> str {
    let out = s;
    while (dwidth(out) < n) { out += " " };
    out
};

def lpad(s: str, n: long) -> str {
    let out = s;
    while (dwidth(out) < n) { out = " " + out };
    out
};

// A rule of `n` dashes, for the section separators.
def rule(n: long) -> str {
    let out = "";
    let i = 0;
    while (i < n) {
        out += "-";
        i = i + 1;
    };
    out
};

// Percent-encode for a URL query value: everything outside [a-z0-9_-]
// becomes %XX. A city typed as `reyk javik` becomes `reyk%20javik`, which
// is what lets the service see a malformed slug and answer 400 instead of
// the request never arriving.
def pct(s: str) -> str {
    let hexd = "0123456789ABCDEF";
    let out = "";
    let i = 0;
    while (i < s.length) {
        let c = ord(s[i:i + 1]);
        if (c >= 97 && c <= 122 || c >= 48 && c <= 57 || c == 45 || c == 95) {
            out += chr(c);
        } else {
            let hi = (c >> 4) & 15;
            let lo = c & 15;
            out += "%";
            out += hexd[hi:hi + 1];
            out += hexd[lo:lo + 1];
        };
        i = i + 1;
    };
    out
};

// ── weather glyphs ──────────────────────────────────────────────────────
//
// chr() cannot make a non-ASCII glyph: it is byte-oriented, so chr(9608)
// is one byte and ord(chr(9608)) is 136 (SUGGESTIONS.md 11). Each glyph is
// therefore written as its UTF-8 bytes, one chr() per byte, which is also
// the shape to use for any non-ASCII text this program emits. The codepoint
// is named so the table can be read.
def g3(a: long, b: long, c: long) -> str {
    let s = chr(a);
    s += chr(b);
    s += chr(c);
    s
};

const G_SUN = 9728;        // U+2600 BLACK SUN WITH RAYS      E2 98 80
const G_CLOUD = 9729;      // U+2601 CLOUD                     E2 98 81
const G_UMBRELLA = 9730;   // U+2602 UMBRELLA                  E2 98 82
const G_SHADE = 9618;      // U+2592 MEDIUM SHADE              E2 96 92
const G_SNOWFLAKE = 10052; // U+2744 SNOWFLAKE                  E2 9D 84
const G_THUNDER = 9928;    // U+26C8 THUNDER CLOUD AND RAIN     E2 9B 88
const G_DOT = 183;         // U+00B7 MIDDLE DOT, second of C2 B7

// The pictogram for a WMO weather code, or a middle dot when the code is
// one this example does not know. Never a trap: an unknown code from the
// live API is a display question, not a fatal one.
def glyph(code: long) -> str {
    if (code == 0 || code == 1) { g3(226, 152, 128) }
    else if (code == 2 || code == 3) { g3(226, 152, 129) }
    else if (code == 45 || code == 48) { g3(226, 150, 146) }
    else if (code >= 51 && code <= 57 || code >= 61 && code <= 67 || code >= 80 && code <= 82) { g3(226, 152, 130) }
    else if (code >= 71 && code <= 77 || code == 85 || code == 86) { g3(226, 157, 132) }
    else if (code >= 95 && code <= 99) { g3(226, 155, 168) }
    else { g2(194, G_DOT) }
};

// ── the WMO code table, as text ─────────────────────────────────────────
def describe(code: long) -> str {
    if (code == 0) { "clear sky" }
    else if (code == 1) { "mainly clear" }
    else if (code == 2) { "partly cloudy" }
    else if (code == 3) { "overcast" }
    else if (code == 45 || code == 48) { "fog" }
    else if (code >= 51 && code <= 57) { "drizzle" }
    else if (code >= 61 && code <= 67) { "rain" }
    else if (code >= 71 && code <= 77) { "snow" }
    else if (code >= 80 && code <= 82) { "rain showers" }
    else if (code == 85 || code == 86) { "snow showers" }
    else if (code >= 95 && code <= 99) { "thunderstorm" }
    else { "code " + tostring(code) }
};

// A signed temperature with a degree sign: -3 °C. The degree sign is
// U+00B0, two UTF-8 bytes (C2 B0).
def deg_c(c: long) -> str { tostring(c) + " " + g2(194, 176) + "C" };
def deg_f(f: long) -> str { tostring(f) + " " + g2(194, 176) + "F" };

def g2(a: long, b: long) -> str {
    let s = chr(a);
    s += chr(b);
    s
};

// mph in tenths, printed with exactly one decimal: 14.9 mph.
def mph1(k: long) -> str {
    let t = kmh_to_mph10(k);
    let a = t < 0 ? 0 - t : t;
    let s = tostring(a / 10) + "." + tostring(a % 10);
    if (t < 0) { "-" + s } else { s }
};

export { round_div, magnitude, c_to_f, kmh_to_mph10, deg, pad0, dwidth, rpad, lpad, rule, pct,
         glyph, describe, deg_c, deg_f, mph1, cont, g2, g3,
         G_SUN, G_CLOUD, G_UMBRELLA, G_SHADE, G_SNOWFLAKE, G_THUNDER, G_DOT };
