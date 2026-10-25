// Tail calls recycle the frame (native.y gen_tail_call): a self-call in
// tail position tears its frame down and jumps back to the prologue, so
// tail recursion runs in constant stack space and allocates nothing. The
// probe is the address of a local (`&here`): in a recycled frame it never
// moves, while a real call moves it down one frame per level — ten million
// levels of those would need ~700 MB of stack.

// the trailing value of an if-arm, recursing through `self`
def arm(n: long, base: long) -> long {
    let here = 0;
    let at = ptr_addr(&here);
    let b = if (base == 0) { at } else { base };
    if (n == 0) { b - at } else { self(n - 1, b) }
}

// `return f(...)`, recursing through the function's own name
def via_return(n: long, base: long) -> long {
    let here = 0;
    let at = ptr_addr(&here);
    let b = if (base == 0) { at } else { base };
    if (n == 0) {
        return b - at;
    };
    return via_return(n - 1, b);
}

// a void function: the call before the block's trailing `;` is in tail
// position too
def walk(n: long, base: long, out: [long]) {
    let here = 0;
    let at = ptr_addr(&here);
    let b = if (base == 0) { at } else { base };
    if (n == 0) { out[0] = b - at; } else { self(n - 1, b, out); };
}

// not a tail call: the addition runs after the call returns, so every
// level keeps its frame (a return address and a saved %rbp at least)
def grow(n: long, base: long) -> long {
    let here = 0;
    let at = ptr_addr(&here);
    let b = if (base == 0) { at } else { base };
    if (n == 0) { b - at } else { 0 + self(n - 1, b) }
}

// every argument is evaluated before any parameter is overwritten:
// `a % b` must read the old `a`, not the `b` copied over it
def gcd(a: long, b: long) -> long { if (b == 0) { a } else { self(b, a % b) } }
def fib(n: long, a: long, b: long) -> long { if (n == 0) { a } else { self(n - 1, b, a + b) } }

let out: [long] = [0];
let h = heap_used();
let d_arm = arm(10000000, 0);
let d_ret = via_return(10000000, 0);
walk(10000000, 0, out);
let g = gcd(1071, 462);
let f = fib(90, 0, 1);
let allocated = heap_used() - h;
print(d_arm);
print(d_ret);
print(out[0]);
print(allocated);
print(g);
print(f);
print(grow(1000, 0) >= 16 * 1000);
