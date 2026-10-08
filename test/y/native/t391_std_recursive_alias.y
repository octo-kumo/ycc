// A std unit's RECURSIVE type alias, named by an importer: json.Val is
// `Num | Str | Bool | Null | Arr | JObj`, and Arr/JObj hold Vals again.
//
// When json became a unit of the std pack, its aliases were published as their
// bodies as written, so json.Val travelled as a union of the BARE names Num,
// Str, ... -- which the importer, knowing them only as json.Num, read as unknown
// types: "parameter 'v' has unpassable type ...", and the language server
// (src/tools/lsp/serve.y) stopped compiling. A unit now publishes each alias
// resolved, a recursive one as its tref.

import json;

def wrap(v: json.Val) -> str {
    let m = json.obj();
    m["x"] = v;
    json.stringify(m)
}

print(wrap(json.num(3)));
let a: [json.Val] = [json.num(1), json.str("two")];
print(wrap(json.jarr(a)));
