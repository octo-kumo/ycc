// No value has a type the program does not say: a parameter is annotated;
// an empty array or `none` is bound where its type is declared; a def is
// called after its body is checked, or has its return type written. (A def
// calling itself is checked again with the type the rest of it gives.)
// expect-error: 13:1: error: parameter 'x' has no type (annotate it)
// expect-error: 14:1: error: the type of 'xs' is not fully known (annotate it)
// expect-error: 15:1: error: the type of 'n' is not fully known (annotate it)
// expect-error: 16:1: error: the return type of 'empty' is not fully known (annotate it)
// expect-error: 17:28: error: 'later' is used before its return type is known (annotate it)
// expect-error: 18:9: error: 'later' is used before its return type is known (annotate it)
// expect-error: 20:1: error: the return type of 'spin' is not fully known (annotate it)
// expect-error: 21:26: error: 'self' is used before its return type is known (annotate it)
def f(x) { x };
let xs = [];
let n = none;
def empty() { [] };
def early() -> long { later() + 1 };
let p = later;
def later() { 2 };
def spin(k: long) { self(k) };
def g(k: long) { let h = self; k };
def fact(k: long) { if (k < 2) { 1 } else { k * self(k - 1) } };
print(fact(5));
