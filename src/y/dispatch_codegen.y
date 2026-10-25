// Tag dispatch rows: kinds | optional typed binding | expression.
// The generated casts keep exact record layouts at each handler boundary.
def meta_tag_dispatch(signature: str, rows: [str], otherwise: str) -> str {
    let out = "def " + signature + " { let k = node.k;\n";
    foreach (row in rows) {
        let parts = row.split("|");
        let cond = "";
        foreach (kind in parts[0].split(" ")) {
            if (cond != "") { cond += " || "; };
            cond += "k == K." + kind;
        };
        out += "if (" + cond + ") {";
        if (parts[1] != "") { out += "let " + parts[1] + " = node;"; };
        out += parts[2] + "} else ";
    };
    out + "{" + otherwise + "} };\n"
};
export { meta_tag_dispatch };
