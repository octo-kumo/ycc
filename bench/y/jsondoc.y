// bench/y/jsondoc.y — the json module end to end: build a document, print it,
// parse it back, and walk the result (strings, arrays, maps, the union Val).
import json;
def doc(n: long) -> { str => json.Val } {
    let o = json.obj();
    let items = json.arr();
    for i in 0..n {
        let e = json.obj();
        e["id"] = json.num(i);
        e["name"] = json.str("item" + tostring(i));
        e["ok"] = json.boolean(i % 2 == 0);
        items += json.jobj(e);
    };
    o["items"] = json.jarr(items);
    o
};
def run() -> long {
    let text = json.stringify(doc(8000));
    let back = json.parse(text)!;
    len(text) + json.node_count(json.jobj(back))
};
print(run());
