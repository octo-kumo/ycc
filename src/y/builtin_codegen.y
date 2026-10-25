// Compile-time helpers for intrinsic signatures and name-based dispatch.
def meta_builtin_type(name: str) -> str {
    if (name == "T") { return "type_node({k: K.tname, name: \"T\"})"; };
    if (name.ends_with("?")) { return "type_node({k: K.topt, of: " + self(name[:len(name)-1]) + "})"; };
    if (name == "mutex" || name == "sem") { return "t_" + name + "()"; };
    if (name[0:1] == "[") {
        return "type_node({k: K.tarr, of: " + self(name[1:len(name)-1]) + "})";
    };
    "type_node({k: K.t" + name + "})"
};

// A row is names[?guard]|expression. Dispatch is compiled, never interpreted.
def meta_named_dispatch(signature: str, rows: [str], otherwise: str) -> str {
    let out = "def " + signature + " {\n";
    foreach (row in rows) {
        let bar = index_of(row, "|");
        let spec = row[:bar];
        let guard = index_of(spec, "?");
        let names = guard < 0 ? spec : spec[:guard];
        let cond = "";
        foreach (name in names.split(" ")) {
            if (cond != "") { cond += " || "; };
            cond += "name == \"" + name + "\"";
        };
        if (guard >= 0) { cond = "(" + cond + ") && (" + spec[guard+1:] + ")"; };
        out += "if (" + cond + ") { return " + row[bar+1:] + "; };\n";
    };
    out + otherwise + " };\n"
};
def meta_text_list(parts: [str], separator: str) -> str {
    let out = "";
    for i in 0..len(parts) { if (i > 0) { out += separator; }; out += parts[i]; };
    out
};
export { meta_text_list, meta_builtin_type, meta_named_dispatch };
