// A document owns its analysis, including a cached failure.
import serve from "../serve.y";

let st = serve.server_state(".", "", 0);
let uri = "file:///cache.y";
serve.doc_put(st, uri, "cache.y", "let answer = 42;", 1);
let first = serve.doc_get(st, uri)!;
print("unanalysed: " + tostring(!first.analysis.ready));
print("valid index: " + tostring(is_some(serve.xref_of(st, first))));
print("cached: " + tostring(first.analysis.ready));
serve.doc_put(st, uri, "cache.y", "let unfinished = \"", 2);
let second = serve.doc_get(st, uri)!;
print("new version unanalysed: " + tostring(!second.analysis.ready));
print("bad index: " + tostring(!is_some(serve.xref_of(st, second))));
print("bad index again: " + tostring(!is_some(serve.xref_of(st, second))));
print("failure cached: " + tostring(second.analysis.ready));
print("old version retained: " + tostring(is_some(first.analysis.index)));
serve.doc_drop(st, uri);
print("closed: " + tostring(!serve.doc_has(st, uri) && !is_some(serve.doc_get(st, uri))));
serve.doc_put(st, uri, "cache.y", "let reopened = 7;", 2);
let third = serve.doc_get(st, uri)!;
print("reopened unanalysed: " + tostring(!third.analysis.ready));
print("reopened index: " + tostring(is_some(serve.xref_of(st, third))));
