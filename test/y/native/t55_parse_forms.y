// Forms the parser used to get wrong without a word.
import m from "m55_multiline_export.y";
print(m.ma() + m.mb() + m.mc());   // a multi-line export list

let x = 1;
let y = "two";
let r = {x, y};                    // shorthand for {x: x, y: y}
print(r.x);
print(r.y);
let r2 = {x, z: 3};
print(r2.x + r2.z);
let b = { x };                     // a block, not a record
print(b);

// No condition loops forever, as in C; a return leaves.
def first_over(xs: [long], n: long) -> long {
    let i = 0;
    for (;;) {
        if (xs[i] > n) { return xs[i]; };
        i = i + 1;
    };
    -1
};
print(first_over([1, 5, 9], 4));

def h() { return; };
h();;                              // an empty statement
print("done");
