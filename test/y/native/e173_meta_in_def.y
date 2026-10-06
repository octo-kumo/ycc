// expect-error: 3:26: error: a meta block cannot be inside a def or type body: only the top level and other blocks
def f() -> long { 1 };
def g(n: long) -> long { #{ n }# };
print(g(1));
