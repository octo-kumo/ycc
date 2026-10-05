// fmt.y -- is src/y/ a fixed point? Prints one line per file.
//
// src/y/ is the style fmt targets (LSP.md R3.2), so reformatting it should be
// very nearly a no-op. It is a signal rather than a gate: what is left is the
// author's own layout -- column-aligned record literals, aligned trailing
// comments, blank lines past the first -- which fmt copies through on purpose.
//
//   argv[1]  the file to check
//   argv[2]  where to write the reformatted text, if it differs
//
// Prints SAME, DIFFERS, or REFUSED.

import fmt from "../fmt.y";
import fs;

let got = fs.read_file(argv()[1]);
let src = got!;
let out = fmt.fmt(src);

if (out == none) {
    print("REFUSED");
} else {
    let o = out!;
    if (o == src) {
        print("SAME");
    } else {
        print("DIFFERS");
        fs.write_file(argv()[2], o);
    }
}