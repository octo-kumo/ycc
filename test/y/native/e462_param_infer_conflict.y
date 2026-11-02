// The first call-site type wins; a later call must use it.
// expect-error: 5:8: error: 'f' arg 0: expected long, got str
def f(a) -> long { a };
print(f(1));
print(f("x"));
