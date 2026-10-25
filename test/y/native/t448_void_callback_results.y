// A void callback contract discards the result but preserves its effects.
def discard(f: (long) -> void) -> void { f(7); };
def number(n: long) -> long { print(n); n + 1 };
discard(number);
discard((n: long) => { print(n * 2); "ignored" });
discard((n: long) => { });
print("done");
