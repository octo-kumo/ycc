// json.y -- the parser: every accepted form, every rejection, and the round
// trip. `parse` gives a bare map so a parsed document indexes directly.

import json;

let src = "{\"a\": 1, \"b\": [1, 2, {\"c\": true}], \"d\": null, \"e\": \"s\", \"f\": false}";
let doc = json.parse(src);
print(is_some(doc));
print(json.stringify(doc!));

// key order is the document's, not sorted
print(json.keys_of(doc!));

// values by key, typed
print(json.stringify_val(json.field(json.jobj(doc!), "a")!, 0));
print(json.stringify_val(json.field(json.jobj(doc!), "b")!, 0));
print(is_some(json.field(json.jobj(doc!), "zz")));

// a top-level array or scalar is not an object
print(is_some(json.parse("[1, 2]")));
print(is_some(json.parse("1")));
print(is_some(json.parse("\"s\"")));
print(is_some(json.parse("true")));
print(is_some(json.parse("null")));

// parse_val takes any of them
print(json.stringify_val(json.parse_val("[1, 2]")!, 0));
print(json.stringify_val(json.parse_val("null")!, 0));
print(json.stringify_val(json.parse_val("\"x\"")!, 0));

// ── numbers: the literal text is kept, so all of these round trip ─────────
let nums = ["0", "-0", "1", "-1", "12345", "1.5", "-1.5", "0.0", "1e10",
            "1E10", "1e+10", "1e-10", "3.14159", "9007199254740993"];
foreach (n in nums) {
    let v = json.parse_val(n);
    print(n + " -> " + json.stringify_val(v!, 0));
}

// rejected number forms: leading zero, bare dot, trailing dot, no digits
let bad_nums = ["01", "-01", ".5", "1.", "1e", "1e+", "+1", "1.2.3", "--1", "1 2"];
foreach (n in bad_nums) {
    print(n + " -> " + tostring(is_some(json.parse_val(n))));
}

// ── strings ──────────────────────────────────────────────────────────────
print(json.stringify_val(json.parse_val("\"a\\\"b\"")!, 0));
print(json.stringify_val(json.parse_val("\"a\\\\b\"")!, 0));
print(json.stringify_val(json.parse_val("\"a\\/b\"")!, 0));
print(json.stringify_val(json.parse_val("\"\\b\\f\\n\\r\\t\"")!, 0));
print(json.stringify_val(json.parse_val("\"\\u0041\"")!, 0));
print(json.stringify_val(json.parse_val("\"\\u00e9\"")!, 0));
print(json.stringify_val(json.parse_val("\"\\u20ac\"")!, 0));
print(json.stringify_val(json.parse_val("\"\\ud83d\\ude00\"")!, 0));
print(json.stringify_val(json.parse_val("\"\\u0000\"")!, 0));

// rejected strings: a lone surrogate either way, a short escape, a raw newline
let bad_strs = ["\"\\ud83d\"", "\"\\ude00\"", "\"\\ud83dx\"", "\"\\u00\"",
                "\"\\q\"", "\"\\uZZZZ\"", "\"a\nb\"", "\"unterminated"];
foreach (t in bad_strs) {
    print(t + " -> " + tostring(is_some(json.parse_val(t))));
}

// ── document shape ───────────────────────────────────────────────────────
let bad_docs = ["", "   ", "{", "}", "[", "]", "{\"a\"}", "{\"a\":}",
                "{\"a\": 1,}", "{a: 1}", "[1,]", "[1 2]", "{}{}", "nul",
                "tru", "{\"a\": 1} extra", "[1, 2] junk", "+"];
foreach (t in bad_docs) {
    print("\"" + t + "\" -> " + tostring(is_some(json.parse(t))));
}

// ── errors carry a message and an offset ─────────────────────────────────
let e1 = json.parse_err("{\"a\": }");
print(e1.ok);
print(e1.err);
print(e1.at);

let e2 = json.parse_err("{\"a\": 1} tail");
print(e2.ok);
print(e2.err);
print(e2.at);

let e3 = json.parse_err("");
print(e3.ok);
print(e3.err);

let ok = json.parse_err("{\"k\": [1, \"two\"]}");
print(ok.ok);
print(ok.at);
print(json.stringify_val(ok.value!, 0));

// ── round trip: parse then stringify is the identity on canonical input ───
let canon = "{\"a\":1,\"b\":[1,2],\"c\":{\"d\":null},\"e\":\"x\",\"f\":true,\"g\":1.5}";
print(json.stringify(json.parse(canon)!));
let rt = json.stringify(json.parse(json.stringify(json.parse(canon)!))!);
print(rt);
print(rt == canon);

// ── the depth bound ──────────────────────────────────────────────────────
// parse is recursive, so a document nested past the bound is refused rather
// than run off the stack.
let deep = "";
let k = 0;
while (k < 260) { deep += "["; k = k + 1; }
k = 0;
while (k < 260) { deep += "]"; k = k + 1; }
print(is_some(json.parse_val(deep)));
let ok_deep = "[";
k = 0;
while (k < 100) { ok_deep += "["; k = k + 1; }
k = 0;
while (k < 100) { ok_deep += "]"; k = k + 1; }
print(is_some(json.parse_val(ok_deep)));

// ── duplicate keys: last one wins, first position kept ───────────────────
let dup = json.parse("{\"a\": 1, \"b\": 2, \"a\": 3}");
print(json.stringify(dup!));
print(json.keys_of(dup!));