// check_main.y — CLI driver: read a Y file, print diagnostics as JSON lines.
// Usage: check_main <file.y>
// Output: one JSON object per line: {"line":N,"col":N,"severity":"...","message":"..."}
// Compiled to wasm for the playground's live diagnostics.
import check from "./check.y";

let args = argv();
if (len(args) < 2) {
    print("usage: check_main <file.y>");
} else {
    let src = read_file(args[1]);
    let diags = check.check(src);
    foreach (d in diags) {
        print("{\"line\":" + tostring(d.line) + ",\"col\":" + tostring(d.col) +
              ",\"severity\":\"" + d.severity + "\",\"message\":\"" + d.message + "\"}");
    };
};
