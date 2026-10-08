// print of a value the emitter cannot see is still the general path: the
// string helper must stay linked (src/tools/ytest/su_treeshake.y gates both ways).
let who = "world";
print("hello " + who);
