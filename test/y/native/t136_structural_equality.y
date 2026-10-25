// == and != look inside options and nested arrays. Two options are equal
// when both are none, or both are some with equal payloads, each payload
// compared with its own ==. An array whose elements are arrays or options
// compares length, then each pair of elements the same way, at any depth.
// Records and maps stay identities, wherever they appear.

let n: long? = none;
let n2: long? = none;
let s1 = some(1);

// options
print(some(1) == some(1));
print(some(1) == some(2));
print(some(1) != some(1));
print(some(1) != some(2));
print(s1 == s1);
print(n == some(1));
print(some(1) == n);
print(n == n2);
print(n != n2);
print(s1 != n);
print(n == none);
print(none == n);
print(s1 == none);

// the payload's own ==
print(some("ab") == some("a" + "b"));
print(some("a") == some("b"));
print(some([1, 2]) == some([1, 2]));
print(some([1, 2]) == some([1, 2, 3]));
print(some(some(1)) == some(some(1)));
print(some(some(1)) == some(some(2)));
let one = 1.0;
let nz = 0.0 * -one;  // a negative zero: 0.0 == nz, as numbers
print(some(0.0) == some(nz));
print(some(1.5) != some(2.5));
let b1: byte = 65;
let b2: byte = 66;
print(some(b1) == some(b1));
print(some(b1) == some(b2));
print(some(true) == some(true));

// records are identities, inside an option too
let r = {x: 1};
print({x: 1} == {x: 1});
print(some(r) == some(r));
print(some({x: 1}) == some({x: 1}));
print([r] == [r]);
print([{x: 1}] == [{x: 1}]);

// nested arrays
print([[1, 2]] == [[1, 2]]);
print([[1, 2]] == [[1, 3]]);
print([[1], [2]] == [[1]]);
print([[1, 2]] != [[1, 2]]);
print([["a", "b"], ["c"]] == [["a", "b"], ["c"]]);
print([["a"]] == [["b"]]);
let bs: [[byte]] = [bytes("hi")];
print(bs == [bytes("hi")]);
print(bs == [bytes("ho")]);
print([[[1], [2, 3]]] == [[[1], [2, 3]]]);
print([[[1], [2, 3]]] == [[[1], [2, 4]]]);
let e: [[long]] = [];
print(e == []);
print([[1]] == e);
print([[]] == e);

// float elements compare as numbers, not as bit patterns
print([0.0] == [nz]);
print([[1.5, 0.0]] == [[1.5, nz]]);
print([0.5] == [1.5]);

// arrays of options
print([some(1), n] == [some(1), n]);
print([n] == [some(1)]);
print([[some("x")]] == [[some("x")]]);
print([[some("x")]] == [[some("y")]]);
print([some([1])] == [some([1])]);

// map reads are options too
let m: {str => long} = {};
m["a"] = 1;
m["b"] = 1;
print(m["a"] == some(1));
print(m["a"] == m["b"]);
print(m["a"] == m["zz"]);
print(m["zz"] == m["yy"]);
print(m["zz"] == none);

// each side runs once, left then right
let trace: [str] = [];
def lo(s: str, v: long?) -> long? { trace += s; v };
def la(s: str, v: [[long]]) -> [[long]] { trace += s; v };
print(lo("l", some(5)) == lo("r", some(5)));
print(la("L", [[1]]) != la("R", [[2]]));
print(trace);

// a long walk ends on its last pair
let big: [[long]] = [];
for i in 0..1000 { big += [[i, i + 1]]; };
let big2: [[long]] = [];
for i in 0..1000 { big2 += [[i, i + 1]]; };
print(big == big2);
big2[999] = [999, 0];
print(big == big2);
