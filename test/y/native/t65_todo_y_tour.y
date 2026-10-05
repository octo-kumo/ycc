// The TODO.y wish-list tour: ternary (also as a void statement), a def
// ending in ';' returns void, defaults + tail recursion, record unions with
// ';'-separated type fields, match with destructuring / binding / '_ => ()',
// string slicing and indexing, byte literals, slice assignment.
let a = true;
let b = a ? 1 : 3;
print(b);
def printa() {
    print("a = ", a);
}
a ? printa() : none;
def factorial(n: long, acc = 1) {
    if (n <= 1) {
        return acc;
    }
    return factorial(n - 1, n * acc);
}
print(factorial(5));
type A = {
    field1: long;
    field2: float;
};
type B = {
    bfield: long;
};
type C = A | B;
let c: C = {
    field1: 1,
    field2: 2.0
};
let c2: C = {
    bfield: 10
};
match c {
    A { field1, field2 } => {
        print("Matched A: ", field1, ", ", field2);
    },
    B b => {
        print("Matched B: ", b.bfield);
    },
    _ => ()
};
match c2 {
    A { field1, field2 } => {
        print("Matched A: ", field1, ", ", field2);
    },
    B b => {
        print("Matched B: ", b.bfield);
    },
    _ => ()
};
let text = "hello world";
print(text[2:5]);
print(text[1]);
let c = c'a'; // expect-warning: 'c' is declared more than once; the last declaration counts (the earlier one at line 27)
print(c);
let buf:[byte] = [1, 2, 3, 4, 5];
let buf2:[byte] = [6, 7, 8];
buf[0:3] = buf2;
buf[2:4] = buf2[0:2];
print(buf);
