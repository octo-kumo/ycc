// a captured variable on the RIGHT of a comparison in a condition
def lit_left(v: long) -> bool { let g = () => { if (4 == v) { true } else { false } }; g() };
def lt(v: long) -> bool { let g = () => { if (3 < v) { true } else { false } }; g() };
def ne(v: long) -> bool { let g = () => { if (4 != v) { true } else { false } }; g() };
def both(x: long, v: long) -> bool { let g = () => { if (x == v) { true } else { false } }; g() };
print(lit_left(4)); print(lit_left(5));
print(lt(4)); print(lt(3));
print(ne(4)); print(ne(5));
print(both(7, 7)); print(both(7, 8));
let xs = [1, 2, 3];
let hits = 0;
let want = 2;
xs.foreach((x) => { if (x == want) { hits += 1; } });
print(hits);
