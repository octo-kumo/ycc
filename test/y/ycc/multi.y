def f(x: long) -> long { x + 1 };
def g(x: long) -> long { f(x) * 2 };
def h(x: long) -> long { g(x) - 1 };
export { f, g, h };
