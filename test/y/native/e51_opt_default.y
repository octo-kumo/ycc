// expect-error: optional parameter 'a' cannot have a default (it is none when left out)
def f(a?: long = 1) -> long { 0 };
print(f());
