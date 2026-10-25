// Shape-preserving renames: * visits one child, [] visits an ordered list.
// Ordinary fields are copied. Every visit threads the scope state forward.
#{
    let shapes = [
        "while While cond* body*",
        "for For init* cond* step* body*",
        "sliceassign SliceAssign arr* lo* hi* v*",
        "un Un op e*",
        "addrderef Wrap e*",
        "bin Bin op l* r*",
        "incdec IncDec op pre tgt*",
        "opassign OpAssign op tgt* v*",
        "store Store p* v*",
        "ret Wrap e*",
        "array ArrLit elems[]",
        "arrrep ArrRep v* n",
        "reclit RecLit keys vals[]",
        "maplit RecLit keys vals[]",
        "index Index arr* idx*",
        "slice Slice arr* lo* hi*",
        "idxassign IdxAssign arr* idx* v*",
    ];
    let out = "";
    foreach (shape in shapes) {
        let parts = shape.split(" ");
        let name = parts[0];
        let typ = parts[1];
        out += "def rn_" + name + "(node: " + typ + ", st: RnSt) -> RnRes {\n";
        let fields = "k: node.k, line: node.line, col: node.col";
        let state = "st";
        for i in 2..len(parts) {
            let field = parts[i];
            let value = "node." + field;
            let list = field[len(field) - 2:] == "[]";
            let child = field[len(field) - 1:] == "*";
            if (list || child) {
                field = field[:len(field) - (list ? 2 : 1)];
                let result = "r" + tostring(i);
                let visit = list ? "rn_list" : "rn_node";
                out += "let " + result + " = " + visit + "(node." + field + ", " + state + ");\n";
                value = result + (list ? ".nodes" : ".node");
                state = result + ".st";
            };
            fields += ", " + field + ": " + value;
        };
        out += "let result: " + typ + " = {" + fields + "};\n";
        out += "let renamed: Node = result;\n{st: " + state + ", node: renamed}\n};\n";
    };
    // Dispatch only the shapes with binding-sensitive behavior; literals
    // and the remaining leaves pass through unchanged.
    let handlers = [
        "un rn_un",
        "addr rn_addrderef",
        "deref rn_addrderef",
        "bin rn_bin",
        "call rn_call",
        "kw_if rn_if",
        "kw_while rn_while",
        "block rn_blocknode",
        "decl rn_decl",
        "func rn_func",
        "assign rn_assign",
        "incdec rn_incdec",
        "opassign rn_opassign",
        "store rn_store",
        "ret rn_ret",
        "array rn_array",
        "arrrep rn_arrrep",
        "rec rn_reclit",
        "map rn_maplit",
        "index rn_index",
        "slice rn_slice",
        "dot rn_dot",
        "idxassign rn_idxassign",
        "dotassign rn_dotassign",
        "kw_foreach rn_foreach",
        "forrange rn_forrange",
        "kw_for rn_for",
        "sliceassign rn_sliceassign",
        "rectest rn_typed_e",
        "narrow rn_typed_e",
        "matchend rn_matchend",
    ];
    out += "def rn_node_go(node: Node, st: RnSt) -> RnRes {\n";
    out += "if (node.k == K.id) { let id: Leaf = node; return rn_id(st, id.v, id.line, id.col); };\n";
    foreach (handler in handlers) {
        let parts = handler.split(" ");
        out += "if (node.k == K." + parts[0] + ") { return " + parts[1] + "(node, st); };\n";
    };
    out + "{st: st, node: node} };\n"
}#
