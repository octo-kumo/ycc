// A primitive union member is boxed in a hidden one-field record, so a
// `long | str | bool | float` value can be built from any arm and read back
// through the matching `if let`.
type V = long | str | bool | float;

def kind(v: V) -> long {
    if let long x = v { let n = x; return n - n + 1; };
    if let str s = v { let n = s.length; return n - n + 2; };
    if let bool b = v { if b { return 3; } else { return 3; }; };
    if let float f = v { let n = f; if n == n { return 4; } else { return 4; }; };
    0
};

def main() -> long {
    let a: V = 123;
    let b: V = "hello";
    let c: V = true;
    let d: V = 1.5;
    print(kind(a)); print(kind(b)); print(kind(c)); print(kind(d));
    print(a); print(b); print(c); print(d);
    let e: V = 456;
    if let long x = e { print(x + 1); } else { print(0); };
    0
};

exit(main());
