// c ? a : b is `if (c) { a } else { b }`; a block whose last statement
// ends in `;` is void; print takes several arguments.
let a = true;
let b = a ? 1 : 3;
print(b);
print(!a ? "yes" : "no");
// right-associative, lowest precedence
let n = 7;
print(n < 5 ? "small" : n < 10 ? "medium" : "large");
print(n > 1 && n < 9 ? n * 2 : 0);

def printa() {
    print("a = ", a);
}

// void arms are fine as a statement
a ? printa() : none;
!a ? printa() : ();

// `{ 1 }` is 1, `{ 1; }` is void
def one() { 1 }
def nothing() { 1; }
print(one());
nothing();
print(typeof(one));
print(typeof(nothing));

// a trailing `return x;` keeps the value
def pick(x: long) -> long {
    if (x > 0) { return 1; } else { return 2; };
}
print(pick(5), " ", pick(-5));

// a record, an array and a bool in one line
print("r=", {x: 1}, " a=", [1, 2], " t=", true);
