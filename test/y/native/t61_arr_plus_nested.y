// `+` on an array of arrays: [[T]] + [T] appends the [T] as one element,
// [T] + [[T]] prepends it; [[T]] + [[T]] concatenates. `+=` on a [[T]]
// pushes a [T] whole and appends the elements of a [[T]].
let aa: [[long]] = [[1, 2], [3, 4], [5, 6]];
let b = aa + [13, 14];
print(b);
print(aa);
let c = [13, 14] + aa;
print(c);
aa += [7, 8];
print(aa);
let d = aa + [[9]];
print(d);
let e = [1, 2] + [3];
print(e);
let f = [1, 2] + 3;
print(f);
let g = 0 + [1, 2];
print(g);
let ss: [str] = ["x"];
ss += "y";
ss += ["z", "w"];
print(ss);
let rr: [[str]] = [];
rr += ["a", "b"];
rr += [["c"], ["d"]];
print(rr);