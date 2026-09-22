// expect-error: cannot capture 'x'
def outer() -> long { let x = 1; def inner() -> long { x }; inner() };
