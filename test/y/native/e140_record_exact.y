// expect-error: 'ra' arg 0: expected { alpha: long }, got { beta: long, alpha: long }
// expect-error: let 'u': expected { a: long } | { b: long }, got { a: long, c: long }
// expect-error: let 'w': expected { a: long }, got void
// A record goes only where its own type (in any field order) or a union
// holding it is expected: a record with more fields is no { alpha: long },
// and nothing that is not a record is one.
def ra(p: { alpha: long }) -> long { p.alpha };
print(ra({ beta: 2, alpha: 1 }));
type U = { a: long } | { b: long };
let u: U = { a: 1, c: 2 };
let w: { a: long } = print("x");
