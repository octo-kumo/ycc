// bench/y/closures.y — record traffic and closure calls: the shape the
// compiler itself has (records everywhere, functions passed around).
def apply(f: (long) -> long, x: long) -> long {
    f(x)
};

def add3(x: long) -> long {
    x + 3
};

def make_adder(k: long) -> (long) -> long {
    def inner(x: long) -> long {
        x + k
    };
    inner
};

let total = 0;
let i = 0;
while (i < 100000) {
    let r = { a: i, b: i * 2, c: "x" };
    total = total + r.a + r.b;
    total = total + apply(add3, i);
    let add10 = make_adder(10);
    total = total + add10(i);
    i = i + 1;
    0
};
print(total);
