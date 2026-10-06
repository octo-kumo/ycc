// expect-error: the block at e183_meta_emits_nul.y:8 emitted a NUL byte, which cannot be in a source file
def nully() -> str {
    let out = "let a = \"";
    out += "\x00";
    out += "\";\n";
    out
};
let x = #{ nully() }#;
print(x);
