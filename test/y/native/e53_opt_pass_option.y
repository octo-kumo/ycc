// expect-error: 'f' arg 1: expected long, got long?
def f(a: long, b?: long) -> long { a };
print(f(1, some(2)));
