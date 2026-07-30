// emit_main.y — CLI driver: read a Y file, emit AssemblyScript to stdout.
// Usage: emit_main <file.y>
// Compiled to wasm for the browser playground's "Export native wasm" feature.
import emit from "./emit_as.y";

let args = argv();
if (len(args) < 2) {
    print("usage: emit_main <file.y>");
} else {
    let src = read_file(args[1]);
    print(emit.emit(src));
};
