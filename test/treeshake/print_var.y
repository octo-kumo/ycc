// print of a value the emitter cannot see is still the general path: the
// string helper must stay linked (test/sh/test_treeshake.sh gates both ways).
let who = "world";
print("hello " + who);
