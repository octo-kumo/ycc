// An architecture supplies aliases, arity and encoder expressions. Generate
// both assembler entry points so text and predecoded IR cannot drift apart.
def meta_backend_codegen(recipes: [str], forms: [str]) -> str {
    let text = "def enc_insn(buf: [byte], at: long, mn: str, ops: [Operand], lng: bool) -> Encoded {\n";
    let direct = "def enc_form(buf: [byte], at: long, f: long, mn: str, ops: [Operand], lng: bool) -> Encoded {\n";
    foreach (recipe in recipes) {
        let parts = recipe.split("|");
        let aliases = parts[0].split(" ");
        let condition = "";
        foreach (alias in aliases) {
            if (condition != "") { condition += " || "; };
            condition += "mn == \"" + alias + "\"";
        };
        text += "if (" + condition + ") {\n";
        if (parts[1] != "0") {
            text += "let e = need" + parts[1] + "(mn, ops); if (e != \"\") { return enc_err(at, e); };\n";
        };
        text += "return " + parts[2] + "; };\n";
        for id in 0..len(forms) {
            let form = forms[id].split(" ");
            if (form[1] in aliases) {
                direct += "if (f == " + tostring(id) + ") { return " + parts[2] + "; };\n";
            };
        };
    };
    text + "enc_err(at, \"unknown mnemonic '\" + mn + \"'\") };\n" +
        direct + "enc_insn(buf, at, mn, ops, lng) };\n"
};
export { meta_backend_codegen };
