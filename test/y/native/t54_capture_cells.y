// A captured variable lives in one cell from the moment it is bound:
// reads and writes before the closure exists, on paths that never create
// it, and in loop conditions all see the same variable (regression: the
// cell used to be allocated where the closure was created, so code
// emitted earlier kept using the stale frame slot).

// captured on one path only
def one_path(c: bool) -> long {
    let v = 1;
    if (c) { let f = def() -> long { v }; } else { 0 }; // expect-warning: unused variable 'f'
    v = 5;
    v
};
print(one_path(true));
print(one_path(false));

// captured in a while loop whose condition reads it
def while_cond() -> long {
    let i = 0;
    let fs: [() -> long] = [];
    while (i < 3) {
        fs += def() -> long { i };
        i += 1;
    };
    fs[0]() + fs[1]() + fs[2]()
};
print(while_cond());

// a C-style `for` variable is one variable: its closures share it
def c_for() -> long {
    let fs: [() -> long] = [];
    for (let i = 0; i < 3; i++) {
        fs += def() -> long { i * 10 };
    };
    fs[0]() + fs[1]() + fs[2]()
};
print(c_for());

// for-in and foreach variables are fresh per iteration, even when only
// some iterations capture them
def for_in() -> long {
    let fs: [() -> long] = [];
    for k in 0..4 {
        if (k % 2 == 1) { fs += def() -> long { k * 10 }; } else { 0 };
        k // expect-warning: the value of 'k' is not used
    };
    fs[0]() + fs[1]()
};
print(for_in());
def for_each() -> str {
    let fs: [() -> str] = [];
    foreach (s in ["a", "b", "c"]) {
        if (s != "b") { fs += def() -> str { s }; } else { 0 };
        s // expect-warning: the value of 's' is not used
    };
    fs[0]() + fs[1]()
};
puts(for_each() + "\n");

// a captured parameter, written before and after the closure is made
def param_rw(a: long) -> long {
    a += 1;
    let f = def() -> long { a * 2 };
    a += 1;
    f()
};
print(param_rw(1));

// a tail-recursive function's captured parameter: every recycled frame
// gets a fresh cell
def tail_caps(n: long, acc: [() -> long]) -> [() -> long] {
    if (n == 0) { acc } else {
        acc += def() -> long { n };
        tail_caps(n - 1, acc)
    }
};
let none_yet: [() -> long] = [];
let tc = tail_caps(3, none_yet);
print(tc[0]() + tc[1]() * 10 + tc[2]() * 100);

// a nested def sees writes made after it is declared
def late_write() -> long {
    let v = 1;
    def get() -> long { v };
    v = 2;
    get()
};
print(late_write());

// a capturing def whose own name is captured by a closure in its body
def own_name() -> long {
    let base = 1;
    def walk(k: long) -> long {
        let again = def() -> long { walk(k - 1) };
        if (k == 0) { base } else { again() + 1 }
    };
    walk(3)
};
print(own_name());
