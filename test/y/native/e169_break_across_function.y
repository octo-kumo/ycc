// A `break` inside a `def` nested in a loop is a jump out of a function, not
// out of a loop: the closure is a function of its own and has no loop in it.
// The emitter's answer would be a jump to the enclosing function's loop label,
// which assembles and then lands in the middle of an unrelated body, so the
// checker refuses it here instead. The nested `def`s go on to report their own
// consequence -- a body of `break` is void, not the `long` they promise.
// expect-error: 12:27: error: 'break' cannot cross a function boundary
// expect-error: 13:27: error: 'continue' cannot cross a function boundary
def f() -> long {
    let i = 0;
    while i < 3 {
        def g() -> long { break; };
        def h() -> long { continue; };
        i = i + 1;
    };
    0
}
print(f());
