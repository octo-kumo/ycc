// s += x appends in place when the buffer is provably the string's own:
// a str variable that += targets keeps a companion word that every read
// of it clears, so an append statement may extend the buffer its last
// append made instead of copying the whole string.

// many appends to a global: memory within a small factor of the data
let h = heap_used();
let s = "";
for i in 0..5000 { s += "ab"; };
print(len(s));
print(heap_used() - h <= 16 * 2 * 5000);
print(s[0:6] + "|" + s[9994:10000]);

// a local, the same
def build(n: long) -> str {
    let out = "";
    let i = 0;
    while (i < n) {
        out += tostring(i);
        out += ",";
        i = i + 1;
    };
    out += f"<{n}>";
    out
};
print(build(12));

// an alias taken before an append keeps the old value
def alias() -> str {
    let a = "x";
    a += "y";
    let b = a;
    a += "z";
    b += "!";
    a + " " + b
};
print(alias());

// a parameter appends to its own copy; the caller's string is untouched
def suffix(p: str, n: long) -> str {
    for j in 0..n { p += "-" };
    p
};
let base = "base";
print(suffix(base, 3));
print(base);

// an array keeps each value as it was
def keep() -> [str] {
    let w = "w";
    let saved: [str] = [];
    for k in 0..3 {
        w += tostring(k);
        saved += w;
    };
    saved
};
print(keep());
def mixed() -> bool {
    let m = "";
    let snaps: [str] = [];
    for i in 0..200 {
        m += "x";
        if (i % 7 == 0) { snaps += m; };
    };
    let ok = len(m) == 200;
    let j = 0;
    foreach (sn in snaps) {
        if (len(sn) != j * 7 + 1) { ok = false; };
        j = j + 1;
    };
    ok
};
print(mixed());

// s += s doubles; an append inside the right operand is overwritten,
// exactly as by s = s + v
def nest() -> str {
    let t = "ab";
    t += t;
    t += { t += "Q"; "c" };
    t += "d";
    t
};
print(nest());

// a global a function in the right operand appends to or reads
let g = "g";
def bump() -> str {
    g += "!";
    "?"
};
g += "1";
g += bump();
g += "2";
print(g);
def glen() -> long { len(g) };
g += tostring(glen());
print(g);

// the statement's value, when used, is the new string
def used() -> str {
    let u = "u";
    u += "v";
    let r = { u += "w" };
    u += "x";
    r + "/" + u
};
print(used());

// a loop body's last statement is a statement too; "" appends nothing
let z = "";
let zi = 0;
while (zi < 3) { zi = zi + 1; z += "z" };
z += "";
print(z + " " + tostring(len(z)));

// a captured or address-taken string still appends (by copying)
def capt() -> str {
    let c = "c";
    let f = def() -> str { c += "+"; c };
    f();
    c += "=";
    f()
};
print(capt());
def addr() -> str {
    let a = "a";
    let p = &a;
    a += "b";
    *p
};
print(addr());

// tail recursion binds the parameter afresh each round
def rep(n: long, acc: str) -> str {
    if (n == 0) { acc } else {
        acc += "r";
        rep(n - 1, acc)
    }
};
print(rep(4, ""));
