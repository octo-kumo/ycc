// json.y -- the value shapes, the constructors and the printer.
//
// A JSON object is a bare map, so it is indexed directly -- there is no set()
// in the way. Every union member has its own field name, which is what lets
// `if let` tell them apart (a record type is its set of fields, so
// `Num = {v: str}` and `Str = {v: str}` would be the same type).

import json;

let o = json.obj();
o["num"] = json.num(42);
o["neg"] = json.num(0 - 7);
o["frac"] = json.numtext("1.50");
o["exp"] = json.numtext("1e10");
o["big"] = json.numtext("9007199254740993");
o["str"] = json.str("hello");
o["true"] = json.boolean(true);
o["false"] = json.boolean(false);
o["null"] = json.nul();
o["empty_arr"] = json.jarr(json.arr());
let three = json.arr();
three += json.num(1);
three += json.str("two");
three += json.boolean(false);
o["arr"] = json.jarr(three);
o["empty_obj"] = json.jobj(json.obj());
print(json.stringify(o));

// key order is insertion order, and survives
print(json.keys_of(o));

// reads: absent is none, present-and-empty is not
let hit = o["str"];
print(is_some(hit));
print(json.as_str(hit!));
print(is_some(o["nope"]));

// a number is its literal text, so a float round-trips and as_long truncates
let f = o["frac"];
print(json.stringify_val(f!, 0));
print(json.as_long(f!));
print(json.as_long(o["num"]!));

// typed accessors, and the wrong one is none rather than a trap
print(json.as_bool(o["true"]!));
print(json.as_bool(o["num"]!));
print(json.as_long(o["str"]!));
print(json.as_str(o["null"]!));
print(json.is_null(o["null"]!));
print(json.is_null(o["num"]!));

// nested: an object inside a value costs one jobj, a top-level one costs none
let inner = json.obj();
inner["deep"] = json.numtext("2.5");
o["sub"] = json.jobj(inner);
print(json.stringify(o));

// escapes: quote, backslash, and the whole C0 range
print(json.escape("q\"b\\s"));
print(json.escape("\t\n\r"));
let ctrl: [byte] = [];
ctrl += bytes(chr(1));
ctrl += bytes(chr(31));
ctrl += bytes(chr(127));
print(json.escape(from_bytes(ctrl)));

// utf8_put builds what chr cannot: chr is one byte, v mod 256
print(json.utf8_put([], 233));          // e-acute, 2 bytes
print(json.utf8_put([], 8364));         // euro sign, 3 bytes
print(json.utf8_put([], 65));           // ascii, 1 byte
print(json.hex2(0));
print(json.hex2(255));

// the depth bound: stringify gives up rather than recursing forever
let deep = json.obj();
let cur = deep;
let i = 0;
while (i < 5) {
    let nxt = json.obj();
    cur["n"] = json.jobj(nxt);
    cur = nxt;
    i = i + 1;
};
print(json.stringify(deep));
print(json.stringify_val(json.jarr(json.arr()), 0));

// index() boxes what an array read does not, and bounds-checks
let three2 = json.arr();
three2 += json.num(10);
three2 += json.num(20);
let av = json.jarr(three2);
print(is_some(json.index(av, 0)));
print(json.stringify_val(json.index(av, 1)!, 0));
print(is_some(json.index(av, 2)));
print(is_some(json.index(av, 0 - 1)));