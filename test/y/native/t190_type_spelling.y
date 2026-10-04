// A type has one spelling, and it is the one a diagnostic uses (m16).
//
// Every line below is a type as the compiler prints it -- by `typeof`, by
// printing a function value, or in the `<...>` a self-referential type prints
// in place of the cycle -- and beside each one is the diagnostic (or the
// manual) that spells the same type the same way. They used to differ:
// `typeof` rendered with tight spacing, `(long)->long` and `{a: long}`, while
// every diagnostic rendered `(long) -> long` and `{ a: long }`, so the text a
// program read out of a type error and the text it asked `typeof` for were two
// different renderings of one type.
def unary(x: long) -> long { x };
def twice(f: (long, long) -> long, a: long, b: long) -> long { f(a, b) };

print(typeof({ a: 1, b: "x" }));        // e140: expected { a: long }, got void
print(typeof({ a: 1 }));                 // e140 again, one field
print(typeof(unary));                    // e72:  got (long) -> long
print(typeof(twice));                    // e72: the same spelling, nested
print(typeof(1));
print(typeof("s"));
print(typeof([1, 2]));                   // e161: expected [long], got long
print(typeof(bytes("ab")));              // a packed [byte]
let fixed: [long; 3] = [1, 2, 3];
print(typeof(fixed));                    // 06-arrays: expected [long; 5], got [long]
let mm: {str => long} = {};
print(typeof(mm));                       // e25: a map's key and element types
let pl: *long = &fixed[0];
print(typeof(pl));                       // a pointer renders as *T

// A union renders its members, each with the spelling a diagnostic gives it
// (e87, e32).
type Q = { a: long } | { b: long };
let q: Q = { a: 1 };
print(typeof(q));                        // e87: no record in { a: long } | { b: long }

// A self-referential type prints the name where the cycle would be.
type L = { head: long, tail: L? };
let l: L = { head: 1, tail: none };
print(typeof(l));                        // { head: long, tail: L? }
print(l);                                // a VALUE, not a type: {head: 1, tail: none}
// ... and a value whose type is already on the walk prints the name instead.
let deep: L = { head: 1, tail: some({ head: 2, tail: none }) };
print(deep);                              // {head: 1, tail: {head: 2, tail: <L?>}}

// A function value has no printable contents, so it prints its signature --
// the same spelling, wrapped in the `<function ...>` the emitter adds.
print(unary);                            // <function (long) -> long>
print(twice);                            // <function ((long, long) -> long, long, long) -> long>
let rec_of_fn = { n: 7, f: unary };
print(rec_of_fn);                        // {n: 7, f: <function (long) -> long>}

// A mutex and a sem print by name, in both.
let mu = mutex();
let se = sem(0);
print(typeof(mu));
print(typeof(se));