// expect-error: 'f' arg 1: expected long, got none
def f(a: long, b?: long) -> long { a };
print(f(1, none));
