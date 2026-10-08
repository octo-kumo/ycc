// fmt.y -- idempotence over every file given in argv.
//
// format(format(x)) must equal format(x) byte for byte (LSP.md R3.5). The file
// list comes from the lsp suite (src/tools/ytest/su_lsp.y), because std has no recursive directory walk.
//
// A buffer that does not lex is refused rather than formatted (R3.4), and a
// refusal is not a failure: a file with a deliberately unterminated literal is
// one ycc itself cannot read.

import fmt from "../fmt.y";
import fs;

let files = argv();
let checked = 0;
let refused = 0;
let not_idempotent = 0;

let i = 1;                       // argv[0] is this program
while (i < len(files)) {
    let got = fs.read_file(files[i]);
    if (got != none) {
        let src = got!;
        let once = fmt.fmt(src);
        if (once == none) {
            refused = refused + 1;
        } else {
            let a = once!;
            let twice = fmt.fmt(a);
            checked = checked + 1;
            if (twice == none) {
                not_idempotent = not_idempotent + 1;
                print("NOT-IDEMPOTENT second-pass-refused " + files[i]);
            } else if (a != twice!) {
                not_idempotent = not_idempotent + 1;
                print("NOT-IDEMPOTENT " + files[i]);
            }
        }
    } else {
        print("SKIP unreadable " + files[i]);
    }
    i = i + 1;
}

print("checked " + tostring(checked) +
      " refused " + tostring(refused) +
      " not-idempotent " + tostring(not_idempotent));