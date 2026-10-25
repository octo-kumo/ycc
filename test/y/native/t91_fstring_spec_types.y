// An f-string field and its format spec against every type a field may
// hold: the integers, the float, the string, a bool, the bytes, an array,
// a record, a map, an option and a union -- with the specs each of them
// takes, and none at all. A field that holds an aggregate is formatted by
// its tostring text whatever the spec says, and a `?.` chain or an
// `if let` inside a field gives the same answer as a plain variable.
type Rect = { w: long, h: long };
type Named = { label: str, w: long };
type Shape = Rect | Named;

let num = 255;
let neg = -255;
let ratio = 1.5;
let txt = "abcdef";
let flag = true;
let raw: [byte] = bytes("AZ");
let arr: [long] = [1, 2, 3];
let rec: Rect = { w: 2, h: 3 };
let mp: {str => long} = { "k": 9 };
let opt: long? = some(7);
let none_opt: long? = none;
let sh: Shape = { label: "sq", w: 4 };

// no spec: the tostring text of each
print(f"{num}", " ", f"{neg}", " ", f"{ratio}", " ", f"{txt}", " ", f"{flag}");
print(f"{raw}", " ", f"{arr}", " ", f"{rec}", " ", f"{mp}", " ", f"{opt}", " ", f"{none_opt}", " ", f"{sh}");

// the integer specs
print(f"{num:x}", " ", f"{num:X}", " ", f"{num:o}", " ", f"{num:b}", " ", f"{num:d}", " ", f"{65:c}", " ", f"{90:3c}|");
print(f"{neg:#x}", " ", f"{neg:+d}", " ", f"{neg: d}", " ", f"{num:,}", " ", f"{num:_}", " ", f"{neg:#o}");

// width, fill and align, on each kind that takes them
print(f"{num:>8}|", " ", f"{num:<8}|", " ", f"{num:^8}|", " ", f"{num:*>8}|", " ", f"{num:08}|");
print(f"{txt:>8}|", " ", f"{txt:<8}|", " ", f"{txt:^8}|", " ", f"{txt:.8}|", " ", f"{txt:.2}|");
print(f"{flag:>7}|", " ", f"{rec:>12}|", " ", f"{arr:>10}|", " ", f"{raw:>14}|", " ", f"{mp:>10}|");
print(f"{opt:>6}|", " ", f"{none_opt:>8}|", " ", f"{sh:>10}|");

// the float specs, with and without a precision
print(f"{ratio:f}", " ", f"{ratio:.3f}", " ", f"{ratio:e}", " ", f"{ratio:E}", " ", f"{ratio:%}");
print(f"{ratio:>12.4f}|", " ", f"{ratio:^14.2e}|", " ", f"{-ratio:+.3f}");

// `s` asks for the text of any value
print(f"{flag:s}", " ", f"{rec:s}", " ", f"{arr:s}", " ", f"{opt:s}", " ", f"{none_opt:s}");

// a field holding a `?.` chain, with and without a spec: the chain's type
// is what the spec is checked against
type Cfg = { port: long, host: str };
type Deep = { cfg: Cfg? };
def here() -> Deep? { some({ cfg: some({ port: 255, host: "h" }) }) };
def gone() -> Deep? { none };
print(f"{here()?.cfg?.port}", " ", f"{gone()?.cfg?.port}", " ", f"{here()?.cfg?.host}");
print(f"{here()?.cfg?.port:4}", " ", f"{unwrap(here()?.cfg?.port):x}", " ", f"{here()?.cfg?.port:>6}|");
print(f"{here()?.cfg?.host:s}", " ", f"{here()?.cfg?.host:>6}|", " ", f"{here()?.cfg?.host:.4}");

// an `if let` as a field's whole expression, and its arms' types
let pick = if let some(v) = opt { v } else { 0 };
print(f"{pick}", " ", f"{pick:4}", " ", f"{(if let some(c) = here()?.cfg { c.host } else { "-" }):>4}|");

// a nested f-string, a doubled brace and a nested field
print(f"{f"{num:>4}|"}", " ", f"{{literal}}", " ", f"{num}+{neg}={num + neg}");