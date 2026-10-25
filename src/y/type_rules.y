// Equality rules after kind checks; recursive aliases and unions are stateful.
#{
    let rules = [
        "tptr TPtr to:type",
        "tint TInt w:value sg:value be:value",
        "tpack TPack bk:value fields:ordered",
        "tarr TOf of:type",
        "tarrfix TFix n:value of:type",
        "tmap TMap key:type of:type",
        "topt TOf of:type",
        "trec TRec fields:fields",
        "tfunc TFunc args:list ret:type",
    ];
    let out = "def teq_shape(a: Type, b: Type) -> bool {\n";
    foreach (rule in rules) {
        let parts = rule.split(" ");
        let test = "";
        for i in 2..len(parts) {
            let field = parts[i].split(":");
            let lhs = "x." + field[0];
            let rhs = "y." + field[0];
            let cmp = lhs + " == " + rhs;
            if (field[1] == "type") { cmp = "teq(" + lhs + ", " + rhs + ")"; }
            else if (field[1] != "value") { cmp = "teq_" + field[1] + "(" + lhs + ", " + rhs + ", 0)"; };
            if (test != "") { test += " && "; };
            test += cmp;
        };
        out += "if (a.k == K." + parts[0] + ") { let x: " + parts[1] + " = a; let y: " + parts[1] + " = b; return " + test + "; };\n";
    };
    out + "true };\n"
}#

// Promotion priority is independent of operator validation and machine lowering.
#{
    let numeric = ["long", "byte", "float", "bigint"];
    let test = "";
    foreach (kind in numeric) {
        if (test != "") { test += " || "; };
        test += "t.k == K.t" + kind;
    };
    let out = "def is_num_kind(t: Type) -> bool { " + test + " };\n";
    out += "def type_numeric_result(left: Type, right: Type) -> Type {\n";
    foreach (kind in ["bigint", "float"]) {
        out += "if (left.k == K.t" + kind + " || right.k == K.t" + kind + ") { return type_node({k: K.t" + kind + "}); };\n";
    };
    out + "type_node({k: K.tlong}) };\n"
}#
