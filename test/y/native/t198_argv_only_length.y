// argv() has to be materialised by the _start prologue however the program
// reads it. The prologue's y_argv_init is emitted only when a scan of the
// AST sees argv(), and that scan had no arm for a field read, so every shape
// below -- `argv().length`, the length reached through a call's argument --
// left %r15 untouched and the program died on SIGSEGV with no output. A
// program that also read anything else off argv (`av[0]`, or `let av =
// argv()`) kept the initialiser alive, which is why this shape shipped.
//
// Every line prints a fact about argv that holds however the program was
// invoked: there is always at least argv[0].
print("dot ", argv().length >= 1);

// the same field read, as an argument of a call
print("arg ", argv().length + 0 >= 1);

// bound to a name -- still the field read that the scan missed
let a = argv().length;
print("let ", a >= 1);

// two reads, both the length: the initialiser has to survive both
let b = argv().length;
print("twice ", b >= 1);

// and the two agree, which is the only thing a length is for
print("same ", a == b);