// single-line comment
/* multi-line
   comment */


// ─── types ────────────────────────────────────────────────────────────────────

// primitives
let a: long   = 42;
let b: float  = 3.14;
let c: bool   = true;
let d: str    = "hello";

// array type
let e: [long] = [1, 2, 3];

// map type
let f: {name: str, age: long} = {name: "alice", age: 30};

// function type
let g: (long, long) -> long = def(x: long, y: long) { x + y };

// ─── literals ─────────────────────────────────────────────────────────────────

let int_lit   = 100;
let neg_int   = -7;
let float_lit = 2.718;
let bare_dot  = 5.;            // valid, treated as 5.0
let str_esc   = "tab:\there\nnewline \"quoted\" \x41";
let arr_lit   = [10, 20, 30];
let map_lit   = {x: 1, y: 2};
let x = "1";
let y = "2";
let map_short = {x, y};        // shorthand: same as {x: x, y: y}


// ─── declarations & assignment ────────────────────────────────────────────────

let  mutable = 0;
const frozen = 99;             // const and let are identical right now

mutable = mutable + 1;         // assignment (left side must be a variable)


// ─── operators ────────────────────────────────────────────────────────────────

let arith  = (1 + 2) * 3 - 4 / 2;
let logic  = true == false;
let cmp    = 10 > 5;


// ─── indexing & slicing ───────────────────────────────────────────────────────

let first  = arr_lit[0];       // normal index
let slice1 = arr_lit[1:3];     // start:end
let slice2 = arr_lit[1:];      // start to end  (end defaults to -1)
let slice3 = arr_lit[:2];      // beginning to end (start defaults to 0)


// ─── if / else ────────────────────────────────────────────────────────────────

let result = if (cmp) {
    "big"
} else {
    "small"
};


// ─── named function ───────────────────────────────────────────────────────────

// return type is optional, typechecker will infer it
def add(x: long, y: long) -> long {
    x + y
};

// no return type annotation
def greet(name: str) {
    "hello, " + name
};


// ─── anonymous functions ──────────────────────────────────────────────────────

let square = def(n: long) -> long { n * n };
// as an argument
let transform = def(arr: [long], func: long->long) {/*TODO*/ 1};
let mapped = transform(arr_lit, def(v: long) { v * 2 });


// ─── function calls ───────────────────────────────────────────────────────────

let sum  = add(1, 2);
let hi   = greet("world");

// call on a parenthesized expression
let val  = (def(x: long) { x + 1 })(41);


// ─── recursion via self ───────────────────────────────────────────────────────

def factorial(n: long) -> long {
    if (n == 0) {
        1
    } else {
        n * self(n - 1)   // self = recursive call to factorial
    }
};


// ─── function types as parameters ────────────────────────────────────────────

def apply(f: (long) -> long, x: long) -> long {
    f(x)
};

def compose(
    f: long -> long,
    g: long -> long
) -> (long -> long) {
    def(x: long) { f(g(x)) }
};


// ─── blocks ───────────────────────────────────────────────────────────────────

// semicolon-separated expressions, value is the last one
let computed = {
    let tmp = 10;
    tmp = tmp * 2;
    tmp + 1          // 21
};


// ─── complex map & array types ────────────────────────────────────────────────

let matrix: [[long]]            = [[1, 2], [3, 4]];
let lookup: {key: [long]}       = {key: [1, 2, 3]};
let nested_fn: ([long]) -> long = def(xs: [long]) { xs[0] };