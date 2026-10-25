// Compile-time generator shared by the Node and Type schemas. No compiler
// types are needed here: shapes name fields and child containers as text.
def meta_shape_codegen(base: str, prefix: str, common: str, shapes: [str], existing: [str], bags: [str]) -> str {
    let declarations = "";
    let members = "";
    let mapping = "";
    let visiting = "";
    let searching = "";
    foreach (shape in shapes) {
        let parts = shape.split(" ");
        let name = parts[0];
        if (members != "") { members += " | "; mapping += ",\n"; visiting += ",\n"; searching += ",\n"; };
        members += name;
        let fields = "";
        let values = "";
        let visits = "";
        let tests = "";
        let specs = common.split(" ") + parts[1:];
        foreach (spec in specs) {
            let field = spec.split(":");
            let key = field[0];
            let typ = field[1];
            if (fields != "") { fields += ", "; values += ", "; };
            fields += key + ": " + typ;
            let value = "n." + key;
            let test = "";
            if (typ == base) {
                value = "fn(" + value + ")";
                test = value;
                visits += value + ";";
            } else if (typ == "[" + base + "]") {
                visits += "foreach (child in " + value + ") { fn(child); };";
                test = prefix + "_any_list(" + value + ", fn)";
                value = prefix + "_map_list(" + value + ", fn)";
            } else {
                foreach (bag in bags) {
                    let info = bag.split(" ");
                    if (typ == "[" + info[0] + "]") {
                        visits += prefix + "_each_" + info[0] + "(" + value + ", fn);";
                        test = prefix + "_any_" + info[0] + "(" + value + ", fn)";
                        value = prefix + "_map_" + info[0] + "(" + value + ", fn)";
                    };
                };
            };
            if (test != "") { if (tests != "") { tests += " || "; }; tests += test; };
            values += key + ": " + value;
        };
        if (!(name in existing)) { declarations += "type " + name + " = {" + fields + "};\n"; };
        if (visits == "") {
            mapping += name + " _n => { node }";
            visiting += name + " _n => { }";
            searching += name + " _n => false";
        } else {
            mapping += name + " n => { let mapped: " + name + " = {" + values + "}; let result: " + base + " = mapped; result }";
            visiting += name + " n => {" + visits + "}";
            searching += name + " n => (" + tests + ")";
        };
    };
    let mapfn = "fn: (" + base + ")->" + base;
    let eachfn = "fn: (" + base + ")->void";
    let anyfn = "fn: (" + base + ")->bool";
    let helpers = "";
    foreach (bag in bags) {
        let info = bag.split(" ");
        let item = info[0];
        let child = info[1];
        let values = child + ": fn(n." + child + ")";
        for i in 2..len(info) { values += ", " + info[i] + ": n." + info[i]; };
        helpers += "def " + prefix + "_map_" + item + "(xs: [" + item + "], " + mapfn + ") -> [" + item + "] { let out: [" + item + "] = []; foreach (n in xs) { out += {" + values + "}; }; out };\n";
        helpers += "def " + prefix + "_each_" + item + "(xs: [" + item + "], " + eachfn + ") -> void { foreach (n in xs) { fn(n." + child + "); }; };\n";
        helpers += "def " + prefix + "_any_" + item + "(xs: [" + item + "], " + anyfn + ") -> bool { foreach (n in xs) { if (fn(n." + child + ")) { return true; }; }; false };\n";
    };
    declarations + "type " + base + " = " + members + ";\n" + helpers +
    "def " + prefix + "_map_children(node: " + base + ", " + mapfn + ") -> " + base + " { match node {" + mapping + "} };\n" +
    "def " + prefix + "_each_child(node: " + base + ", " + eachfn + ") -> void { match node {" + visiting + "} };\n" +
    "def " + prefix + "_any_child(node: " + base + ", " + anyfn + ") -> bool { match node {" + searching + "} };\n" +
    "def " + prefix + "_any_list(nodes: [" + base + "], " + anyfn + ") -> bool { foreach (node in nodes) { if (fn(node)) { return true; }; }; false };\n" +
    "def " + prefix + "_map_list(nodes: [" + base + "], " + mapfn + ") -> [" + base + "] { let out: [" + base + "] = []; foreach (node in nodes) { out += fn(node); }; out };\n"
};
