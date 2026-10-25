// A record field holding an aggregate used to print the field's TYPE instead
// of its value:
//
//     print({ a: [7], o: some(2), r: { x: 1 } });
//     # {a: <[long]>, o: <long?>, r: <{ x: long }>}
//
// gen_rec_field_str's last arm said so in a comment: "only gen_val_tostr_rax
// walks them recursively" -- which is exactly what a field needs, so it now
// loads the field and hands it to that walk, and the text matches what
// tostring() gives for the same value. The other arms are unchanged in what
// they print; they just leave the string in %rax for one shared tail now.
type A = { tag: long, v: long };
type B = { tag: long, w: str };
type U = A | B;
type R = { m: {str => long}, o: long?, r: { x: long }, b: [byte], a: [long], s: str, n: long, f: float, t: bool, u: U };

let ua: U = { tag: 1, v: 9 };
let ub: U = { tag: 2, w: "second" };
let em: {str => long} = { };
let raw: [byte] = [1, 2, 255];
let rec: R = { m: { "k": 1 }, o: some(2), r: { x: 1 }, b: raw, a: [7, 8], s: "hi", n: 5, f: 1.5, t: true, u: ua };
let empty: R = { m: em, o: none, r: { x: 0 }, b: raw, a: [ ], s: "", n: 0, f: 0.0, t: false, u: { tag: 1, v: 0 } };

// one field of every shape, values and empty
print(rec);
print(empty);
// a union field, both members
print({ u: ub });
// scalars in a record are untouched
print({ s: "s", n: 1, f: 0.5, t: false });
// an aggregate nested two deep (array of arrays inside two records)
print({ outer: { inner: [[1, 2], [3]] } });
// and the field's own text is tostring() of the value
print(rec.r);
print(rec.a);
print(rec.m);
print(rec.u);
print(tostring(rec) == tostring({ m: { "k": 1 }, o: some(2), r: { x: 1 }, b: raw, a: [7, 8], s: "hi", n: 5, f: 1.5, t: true, u: ua }));
// the fields still read as themselves
print(rec.m["k"], " ", rec.o!, " ", rec.r.x, " ", rec.b[1], " ", rec.a[1], " ", len(rec.a));
// records compare by identity (07-references.tex), so equal text is not ==;
// the arrays and options inside them are structural
print(rec.a == [7, 8], " ", rec.o == some(2), " ", rec == empty);