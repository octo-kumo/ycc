// Returning a [T; N] is safe: the header is allocated on the arena heap, so
// there is nothing to dangle when the frame goes away. This replaces the old
// e07_arrret "dangle" rejection test, which existed while [v; n] lived in
// stack slots.
def make() -> [long; 3] { [7; 3] };

def total(a: [long; 3]) -> long { a[0] + a[1] + a[2] };

let m = make();
print(total(m));
m[2] = 5;
print(total(m));
print(len(m));
