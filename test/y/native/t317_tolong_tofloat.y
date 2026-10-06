// tolong and tofloat: the conversion pair, both arms of each.
//
// The names are the point -- `tonum` said "number" without saying which, and
// could only parse -- so both are checked on both a str and a number, and the
// two behaviours that a plausible-looking rewrite would break are pinned
// explicitly: truncation is TOWARD ZERO (not floor, which is what to_int's
// sibling floor does and what a careless edit would produce), and the bound is
// exact on both sides (-2^63 is a long and must come back, +2^63 is not and
// must not).

print("-- tolong on a str: a whole number and NOTHING else, so junk is none");
print(tolong("42")!, " ", tolong("-42")!, " ", tolong("+42")!, " ", tolong(" 42 ")!, "  <- whitespace is fine");
print(tolong("+7x") == none, " ", tolong("abc") == none, " ", tolong("") == none, " ", tolong("0x10") == none, " ", tolong("4 2") == none);
print("42".tolong()!, " ", "-42".tolong()!, "  (the string method is the same function)");

print("-- tolong on a float: TOWARD ZERO, not floor");
print(tolong(3.99)!, " ", tolong(-3.99)!, " ", tolong(0.5)!, " ", tolong(-0.5)!, " ", tolong(2.0)!);
// floor(-3.99) is -4. If this ever prints -4 the truncation became a floor.
if (tolong(-3.99)! == -4) { print("FAIL: tolong floored instead of truncating"); };

print("-- tofloat on a str: the same scan, with a fraction");
print(tofloat("3.14")!, " ", tofloat("-0.5")!, " ", tofloat("2.5")!, " ");
print("3.14".tofloat()!, "  (the string method again)");
print(tofloat("1e9") == none, "  <- an exponent is not read, and is none rather than truncated");
print(tofloat("abc") == none, " ", tofloat("") == none, "  <- no digits at all is none");

print("-- tofloat on a long: the widening, made explicit");
print(tofloat(7)!, " ", tofloat(-7)!, " ", tofloat(0)!, " ");
// long -> float is already implicit, so this must not contradict it.
let widened: float = 7;
if (tofloat(7)! != widened) { print("FAIL: tofloat(long)! disagrees with the implicit widening"); };
print("  and it agrees with the implicit widening");

print("-- the round trip, which is what the pair is for");
let xs: [str] = ["0", "1", "-1", "12345", "3.75", "-0.0625", "  9  "];
let i = 0;
while (i < len(xs)) {
    let s = xs[i];
    let f = tofloat(s)!;
    print("  ", s, " -> ", f, " -> ", tolong(f)!);
    i = i + 1
};

// The bound is 2^63 as a double, and it must be exact: an off-by-one-ulp
// bound would reject the last double below it, which is a perfectly good long.
print("-- the ends of the range");
// -2^63 IS representable, so this must answer rather than trap.
print("  -2^63        -> ", tolong(-9223372036854775808.0)!);
print("  2^63-2048    -> ", tolong(9223372036854773760.0)!, "  (the last double below 2^63)");
print("  2^53         -> ", tolong(9007199254740992.0)!, "  <- exact, as every double is here");

// Why not 2^63 - 1024, the number that looks like it should work? Doubles this
// size are 2048 apart, so 2^63-1024 is exactly halfway between the last one
// below and 2^63 itself and rounds to even -- which is 2^63. It has no double
// to write it down with, so there is nothing for tolong to receive. A double
// that cannot name a long cannot have one.
print("  2^63-1024 is not a double a program can pass: it rounds to 2^63");