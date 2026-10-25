// expect-error: optional parameter 'a' needs a type ('a?: T')
def f(a?) -> long { 0 };
print(f());
