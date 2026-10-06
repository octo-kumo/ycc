// JSON literals desugar to the ordinary std/json.y constructors: an object
// is a map (or json.jobj nested), an array is json.jarr, and the scalar arms
// preserve their literal text.
import json from "../../../src/y/std/json.y";

def main() -> long {
    let req = json{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "textDocument/hover",
        "params": { "textDocument": { "uri": "file:///a.y" }, "position": { "line": 3, "character": 9 } }
    };
    print(json.stringify(req));

    let arr = json[1, true, null, 2.5, { "x": "y" }, [1, 2, 3], json{}];
    let text = json.stringify_val(arr, 0);
    print(text);
    print(json.stringify_val(json.parse_val(text)!, 0));
    0
};

exit(main());
