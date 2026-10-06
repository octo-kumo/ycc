// expect-error: e186_meta_emits_block.y:7 emitted a #{ … }# block
// A piece is spliced into the program's source and never rescanned, so a block
// inside one would have no generator to run in.
def nested() -> str {
    return "let z = 1;\n" + "#{ \"let q = 2;\\n\" }#";
};
let x = #{ nested() }#;
print(x);
