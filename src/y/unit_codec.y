// Unit fields in wire order: name:type | writer | reader | empty value.
// Empty writers are derived fields; exports/defaults also form the interface.
#{
    let fields = [
        "name:str||name|name",
        "files:[str]|pack_strs(out, u.files)|pack_get_strs(cur)|[]",
        "exports:[Sym]|pack_exports(out, u.exports)|pack_get_exports(cur, bound)|[]",
        "dfl:[DflCode]|pack_defaults(out, u.dfl)|pack_get_defaults(cur)|[]",
        "init:str|pack_put(out, u.init)|pack_get(cur)|\"\"",
        "bodies:[[long]]||[]|[]",
        "blob:[str]|pack_strs(out, pack_bodies(u))|pack_get_strs(cur)|[]",
        "btext:[[str]]|pack_strss(out, u.btext)|pack_get_strss(cur)|[]",
        "labels:[str]|pack_strs(out, u.labels)|pack_get_strs(cur)|[]",
        "refs:[[str]]||blob.map((b) => blob_refs(b))|[]",
        "rodata:[[str]]|pack_strss(out, u.rodata)|pack_get_strss(cur)|[]",
        "globals:[str]|pack_strs(out, u.globals)|pack_get_strs(cur)|[]",
        "tys:[str]|pack_strs(out, u.tys)|pack_get_strs(cur)|[]",
        "fx:[str]|pack_strs(out, u.fx)|pack_get_strs(cur)|[]",
    ];
    let decl = "";
    let values = "";
    let empty = "";
    let read = "def unit_read(cur: Cursor, name: str, bound: bool) -> Unit {\n";
    let write = "def pack_unit_fields(u: Unit) -> str { let out: [str] = [];\n";
    let iface = "def pack_iface(out: [str], u: Unit) -> [str] {\n";
    foreach (row in fields) {
        let parts = row.split("|");
        let field = parts[0].split(":");
        let name = field[0];
        if (decl != "") { decl += ", "; values += ", "; empty += ", "; };
        decl += name + ": " + field[1];
        values += name + ": " + name;
        empty += name + ": " + parts[3];
        if (name != "name") { read += "let " + name + ": " + field[1] + " = " + parts[2] + ";\n"; };
        if (parts[1] != "") { write += "out = " + parts[1] + ";\n"; };
        if (name == "exports" || name == "dfl") { iface += "out = " + parts[1] + ";\n"; };
    };
    "type Unit = {" + decl + "};\n" +
        "def unit_empty(name: str) -> Unit { {" + empty + "} };\n" +
        read + "{" + values + "} };\n" + write + "join(out, \"\") };\n" + iface + "out };\n"
}#
