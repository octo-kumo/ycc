// A qualified type name from a PATH import resolves (native.y strip_type).
//
// `m.T` and bare `T` are the same declaration when `m` names a path import,
// because a path import flattens: the origin map records no module name for it,
// so rename registers the alias bare. Before strip_type, the TYPE side was the
// one place that did not flatten -- the expression side always did -- and a
// reference written the way the manual writes it was rejected:
//
//     import m from "./mod.y";
//     let p: m.Pair = m.mk(1, 2);     error: unknown type 'm.Pair'
//
// while the bare spelling compiled. Both work now, and this checks every place a
// type can appear, because strip_type recurses and a missed arm would leave one
// spelling working in one position and not another.
import imp from "./helper/imp_types.y";

// a let annotation, qualified, and the bare spelling of the same alias
let a: imp.Pair = imp.mk(1, 2);
let b: imp.Pair = imp.mk(3, 4);
// an alias that REFERS to another alias in its own module
let c: imp.Alt = imp.mk(1, 1);
// an alias to an OPTION of an alias
let d: imp.Maybe2 = some(imp.mk(2, 2));
// inside a compound type, at two depths
let arr: [imp.Pair] = [imp.mk(1, 1), imp.mk(2, 2)];
let rec: { x: imp.Pair } = { x: imp.mk(3, 3) };
let mp: { str => imp.Pair } = { "k": imp.mk(4, 4) };
// a parameter and a return type
// a local bound to an imported FUNCTION, the expression side
print(imp.sum(a) + imp.sum(b) + imp.sum(c));
print(arr[0].a + arr[1].b + rec.x.a);
let got = mp["k"];
if is_some(got) { let p = got!; print(p.a + p.b) };
if is_some(d) { let q = d!; print(q.a + q.b) };
print(imp.give().a);
print(imp.sum(imp.give()));
