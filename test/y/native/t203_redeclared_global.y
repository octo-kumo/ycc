// A name declared twice at the top level is legal -- the later declaration
// shadows the earlier one, and rename.y keeps the earlier one under a
// `$shadow` name so a self call inside it still binds to itself (t14, t30,
// t53 pin that). What it is not is knowable from the source: a copy-paste
// that leaves an old copy behind shadows the new one silently, and every
// read of the file shows the copy that is not the one called.
//
// So it warns, naming the line the earlier declaration is on. The cross-file
// case -- two imported units colliding -- stays an error (find_dup, e132 and
// e167): there is no shadowing there, only two files fighting over a name.

// a def shadowed by a later def: the later one runs
def f() -> long { 1 };
def f() -> long { 2 }; // expect-warning: 'f' is declared more than once; the last declaration counts (the earlier one at line 13)
print(f());

// a global rebound, which is the shape an edit loop leaves behind
let g: long = 1;
g = g + 1;
let g: long = g + 1; // expect-warning: 'g' is declared more than once; the last declaration counts (the earlier one at line 18)
print(g);

// a const too: one namespace, one rule
const K: long = 1;
const K: long = 2; // expect-warning: 'K' is declared more than once; the last declaration counts (the earlier one at line 24)
print(K);

// and the forms that must stay silent: distinct names, a name containing
// another, a name a def's parameter shadows (a different scope entirely),
// and a repeated import, which binds the same module once
def f2() -> long { 3 };
def ff() -> long { 4 };
let counter: long = 5;
def param(shadowed: long) -> long { shadowed + 1 };
import fs;
import fs;
print(f2() + ff() + counter + param(6) + len([1, 2]) + (if (fs.exists(".")) { 1 } else { 0 }));