// A thread primitive used as a variable, a field or a def is not a CALL, so it
// is allowed; only `name(` and `def name` are refused inside a block. This file
// is a `t*` in all but name: it compiles, and it prints ok.
type H = { lock: long, join: long, spawn: long };
def use(n: long) -> long { return n };
let h: H = { lock: 1, join: 2, spawn: 3 };
let lock = 4;
let s = use(h.lock + lock);
#{ "print(\"" + tostring(s) + " ok\\n\");\n" }#
