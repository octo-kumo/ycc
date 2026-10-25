// An f-string spec is checked against the field's type, and an aggregate --
// an array, a record, a map, an option, a union, and the option a `?.`
// chain builds -- is formatted by its tostring text, so a numeric spec on
// one is a type error. (An aggregate's spec used to trap the compiler
// instead of reporting this.)
type Rect = { w: long, h: long };
type Named = { label: str, w: long };
type Shape = Rect | Named;
type Cfg = { port: long, host: str };
type Deep = { cfg: Cfg? };

let arr: [long] = [1];
let rec: Rect = { w: 1, h: 2 };
let mp: {str => long} = { "k": 1 };
let opt: long? = some(1);
let sh: Shape = { w: 1, h: 2 };
let deep: Deep? = some({ cfg: some({ port: 1, host: "h" }) });

// expect-error: 20:9: error: format spec 'x': type 'x' needs a number, not [long]
print(f"{arr:x}");
// expect-error: 22:9: error: format spec 'x': type 'x' needs a number, not { w: long, h: long }
print(f"{rec:x}");
// expect-error: 24:9: error: format spec 'x': type 'x' needs a number, not {str => long}
print(f"{mp:x}");
// expect-error: 26:9: error: format spec 'x': type 'x' needs a number, not long?
print(f"{opt:x}");
// expect-error: 28:9: error: format spec 'x': type 'x' needs a number, not { w: long, h: long } | { label: str, w: long }
print(f"{sh:x}");
// expect-error: 30:9: error: format spec '+.2f': type 'f' needs a number, not long?
print(f"{opt:+.2f}");
// expect-error: 32:9: error: format spec 'x': type 'x' needs a number, not long?
print(f"{deep?.cfg?.port:x}");