// expect-error: 'f' body: expected long, got void
// a trailing `;` makes the block void
def f() -> long { 1; }
print(f());
