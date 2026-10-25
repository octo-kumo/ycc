// Shared fixed signatures. The checker owns argument evaluation and diagnostics.
#{
    import schema from "./builtin_schema.y";
    import codegen from "./builtin_codegen.y";
    def comma(xs: [str]) -> str {
        let out = "";
        foreach (x in xs) { if (out != "") { out += ", "; }; out += x; };
        out
    };
    let out = "type BuiltinSpec = {valid: bool, ret: Type, bad: Type, args: [Type], contexts: [str], arity: str, deferred: bool};\n";
    let entries = "";
    let dispatch = "";
    let index = 0;
    foreach (row in schema.BUILTIN_SHAPES) {
        let parts = (row + "~").split("|");
        let note = parts[4][:len(parts[4])-1];
        let name = parts[0];
        let specs = parts[3];
        let deferred = specs[0:1] == "!";
        if (deferred) { specs = specs[1:]; };
        let args: [str] = [];
        let contexts: [str] = [];
        // Semaphores and pid diagnostics include spaces in their argument name.
        let fields = specs.split(" ");
        foreach (field in fields) {
            if (field == "") { continue; };
            if (index_of(field, ":") < 0) {
                contexts[len(contexts)-1] += " " + field;
            } else {
                let colon = index_of(field, ":");
                let label = field[colon+1:];
                args += codegen.meta_builtin_type(field[:colon]);
                contexts += (label[0:1] == "'" ? name : name + " ") + label;
            };
        };
        let n = len(args);
        let arity = n == 0 ? " takes no arguments" : " takes exactly " + tostring(n) + (n == 1 ? " argument" : " arguments");
        let quoted: [str] = [];
        foreach (context in contexts) { quoted += "\"" + context + "\""; };
        entries += "{valid: true, ret: " + codegen.meta_builtin_type(parts[1]) + ", bad: " + codegen.meta_builtin_type(parts[2]) +
            ", args: [" + comma(args) + "], contexts: [" + comma(quoted) + "], arity: \"" + name + arity + note + "\", deferred: " + tostring(deferred) + "},\n";
        dispatch += "if (name == \"" + name + "\") { return builtin_specs[" + tostring(index) + "]; };\n";
        index++;
    };
    entries += "{valid: false, ret: t_unk(), bad: t_unk(), args: [], contexts: [], arity: \"\", deferred: false}";
    out + "let builtin_specs: [BuiltinSpec] = [];\ndef builtin_spec(name: str) -> BuiltinSpec {\n" +
        "if (len(builtin_specs) == 0) { builtin_specs = [" + entries + "]; };\n" + dispatch +
        "builtin_specs[" + tostring(index) + "] };\n"
}#
