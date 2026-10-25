// `{}` where a map is declared -- an argument, an assignment, a return -- is
// the map, not an empty record.
import json;
def count(m: { str => long }) -> long { m["a"] = 1; len(m) };
def mk() -> { str => long } { {} };
print(count({}));
let m: { str => long } = { "z": 2 };
m = {};
print(len(m));
print(len(mk()));
let o = json.obj();
o["a"] = json.num(1);
o["meta"] = json.jobj({});
print(json.stringify(o));
