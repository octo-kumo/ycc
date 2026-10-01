// expect-error: required parameter 'b' cannot follow optional parameter 'a' (optional parameters come last)
def f(a?: long, b: long) -> long { b };
print(f(1, 2));
