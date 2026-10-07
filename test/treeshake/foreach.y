// The foreach half of the parity pair: the literal closure must compile
// like the raw loop above, not to an indirect call per element.
let a: [long] = [1, 2, 3, 4, 5, 6, 7, 8];
let s = 0;
a.foreach((x) => { s += x; });
print(s);
