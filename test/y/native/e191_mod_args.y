// mod is a two-argument whole-number builtin; each of the three ways to miss
// it has its own message.
def a() -> long { mod(1) } // expect-error: 3:22: error: mod takes exactly 2 arguments
def b() -> long { mod(1, 2, 3) } // expect-error: 4:22: error: mod takes exactly 2 arguments
def c() -> long { mod("x", 2) } // expect-error: 5:22: error: mod left: expected long, got str
def d() -> long { mod(1, "x") } // expect-error: 6:22: error: mod right: expected long, got str
print(a() + b() + c() + d());
