// literal_type.y — the type a literal argument gives a missing parameter type.
//
// The parser uses this for a default value's inferred annotation
// (`def f(a = 1)`), and infer_params.y uses the same function on call-site
// arguments and binary operands. One definition keeps the two passes from
// disagreeing about what `1`, `1.0`, `"x"` or `true` implies.

import tags from "./tags.y";
import node_schema from "./ast_nodes.y";
import type_schema from "./type_nodes.y";
import lexer from "./lexer.y";

def lit_type(node: Node) -> Type {
    let k: long = node.k;
    if (k == K.num) {
        let leaf: Leaf = node;
        num_lit_type(leaf.v)
    }
    else if (k == K.bignum) { let ty: Type = { k: K.tbigint }; ty }
    else if (k == K.str) { let ty: Type = { k: K.tstr }; ty }
    else if (k == K.bool) { let ty: Type = { k: K.tbool }; ty }
    else if (k == K.char) { let ty: Type = { k: K.tbyte }; ty }
    else if (k == K.un) {
        let un: Un = node;
        lit_type_neg(un)
    }
    else { let ty: Type = { k: K.tnone }; ty }
};

def lit_type_neg(node: Un) -> Type {
    let e = node.e;
    if (node.op == "-" && e.k == K.num) {
        let leaf: Leaf = e;
        num_lit_type(leaf.v)
    } else { let ty: Type = { k: K.tnone }; ty }
};

// float when the literal has a fraction or an exponent (radix literals
// like 0xE1 never do).
def num_lit_type(s: str) -> Type {
    if (lexer.radix_of(s) != 0) { { k: K.tlong } }
    else if (index_of(s, ".") >= 0 || index_of(s, "e") >= 0 || index_of(s, "E") >= 0) { { k: K.tfloat } }
    else { { k: K.tlong } }
};

export { lit_type, lit_type_neg, num_lit_type };
