// Wire codes and field order for the ordinary types in packs and object files.
// Recursive aliases and record/packed fields have stateful codecs in native.y.
#{
    let shapes = [
        "l tlong", "b tbyte", "f tfloat", "g tbigint", "o tbool",
        "s tstr", "v tvoid", "u tunk", "n tnone",
        "N tname TName name:string",
        "I tint TInt w:digit sg:sign be:endian",
        "* tptr TPtr to:type", "[ tarr TOf of:type", "? topt TOf of:type",
        "F tarrfix TFix n:number of:type",
        "M tmap TMap key:type of:type",
        "> tfunc TFunc args:types ret:type",
        "U tunion TList ts:types", "T tparams TList ts:types",
        "P tpat TPat names:strings",
    ];
    let encode = "def tcode_simple(out: [str], t: Type) -> bool {\n";
    let decode = "def tdecode_go(cur: Cursor) -> Type { let p = cur.p; let c = cur.s[p:p+1]; cur.p++;\n";
    foreach (row in shapes) {
        let parts = row.split(" ");
        encode += "if (t.k == K." + parts[1] + ") { out += \"" + parts[0] + "\";";
        decode += "if (c == \"" + parts[0] + "\") {";
        let fields = "k: K." + parts[1];
        if (len(parts) > 2) { encode += "let n: " + parts[2] + " = t;"; };
        for i in 3..len(parts) {
            let field = parts[i].split(":");
            let key = field[0];
            let kind = field[1];
            let value = "n." + key;
            let put = "";
            let get = "";
            if (kind == "type") { put = "tcode_go(out, " + value + ")"; get = "tdecode_go(cur)"; }
            else if (kind == "types") { put = "tcode_list(out, " + value + ")"; get = "tdecode_list(cur)"; }
            else if (kind == "strings") { put = "pack_strs(out, " + value + ")"; get = "pack_get_strs(cur)"; }
            else if (kind == "string") { put = "pack_put(out, " + value + ")"; get = "pack_get(cur)"; }
            else if (kind == "number") { put = "pack_put(out, tostring(" + value + "))"; get = "pack_num(cur)"; }
            else {
                put = "out += " + (kind == "digit" ? "tostring(" + value + ")" :
                    "(" + value + " ? \"" + (kind == "sign" ? "s" : "b") + "\" : \"" + (kind == "sign" ? "u" : "l") + "\")");
                get = kind == "digit" ? "tolong(cur.s[cur.p:cur.p+1])!" : "cur.s[cur.p:cur.p+1] == \"" + (kind == "sign" ? "s" : "b") + "\"";
            };
            encode += put + ";";
            decode += "let " + key + " = " + get + ";";
            if (kind == "digit" || kind == "sign" || kind == "endian") { decode += "cur.p++;"; };
            fields += ", " + key + ": " + key;
        };
        encode += "return true; };\n";
        decode += "return normtype({" + fields + "}); };\n";
    };
    encode + "false };\n" + decode + "tdecode_special(cur, c) };\n"
}#
