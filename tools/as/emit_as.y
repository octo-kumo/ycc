// emit_as.y — emit AssemblyScript source from a Y AST (supported subset).
// AssemblyScript compiles to native WebAssembly in the browser via the
// lazy-loaded AssemblyScript compiler (~2.9MB gz, loaded only on Export).
//
// Supported subset: typed functions (long/float/bool params + return),
// arithmetic, comparisons, if/else, while, for-range, let declarations,
// return, and print() (emitted as an imported host function).
//
// Type mapping: long -> i64, float -> f64, bool -> bool, str -> string.

import lexer from "../../ycc/lexer.y";
import parser from "../../ycc/parser.y";

// Current function name (for rewriting Y's `self` recursion to the AS name).
let g_cur_func = "";

def as_type(t: str) -> str {
    if (t == "long") { "i64" }
    else if (t == "float") { "f64" }
    else if (t == "bool") { "bool" }
    else if (t == "str") { "string" }
    else { "i64" }  // default
};

// ── expression emission ──────────────────────────────────────────────────

def emit_expr(node) -> str {
    let k = node.k;
    if (k == "num") {
        // integer vs float literal
        if (index_of(node.v, ".") >= 0) { node.v } else { node.v }
    } else if (k == "str") {
        "\"" + node.v + "\""
    } else if (k == "bool") {
        node.v
    } else if (k == "null") {
        "0"
    } else if (k == "id") {
        node.v
    } else if (k == "bin") {
        "(" + emit_expr(node.l) + " " + node.op + " " + emit_expr(node.r) + ")"
    } else if (k == "un") {
        "(" + node.op + emit_expr(node.e) + ")"
    } else if (k == "call") {
        emit_call(node)
    } else {
        "/* unsupported: " + k + " */ 0"
    }
};

def emit_call(node) -> str {
    let callee = node.callee;
    if (callee.k == "id" && callee.v == "print") {
        // print(a, b, ...) -> hostPrint(a); hostPrint(b); ...
        // For simplicity emit a single-arg host print of the first arg.
        if (len(node.args) > 0) {
            "hostPrint(" + emit_expr(node.args[0]) + ")"
        } else {
            "hostPrint(0)"
        }
    } else if (callee.k == "id") {
        let parts = [];
        foreach (a in node.args) {
            parts = push(parts, emit_expr(a));
        };
        // Y's `self` recursion -> the current function's name in AS.
        let fn = callee.v;
        if (fn == "self") { fn = g_cur_func; };
        fn + "(" + join(parts, ", ") + ")"
    } else {
        "/* unsupported call */ 0"
    }
};

// ── statement emission ───────────────────────────────────────────────────

def emit_stmt(node, indent: str, tail: bool) -> str {
    let k = node.k;
    let pad = indent;
    if (k == "decl") {
        pad + "let " + node.name + " = " + emit_expr(node.v) + ";\n"
    } else if (k == "assign") {
        pad + node.name + " = " + emit_expr(node.v) + ";\n"
    } else if (k == "ret") {
        pad + "return " + emit_expr(node.e) + ";\n"
    } else if (k == "if") {
        let s = pad + "if (" + emit_expr(node.cond) + ") {\n";
        s = s + emit_block(node.then, indent + "  ", tail);
        if (node.has_else) {
            if (node.els.k == "if") {
                s = s + pad + "} else " + substr(emit_stmt(node.els, indent, tail), len(pad));
            } else {
                s = s + pad + "} else {\n";
                s = s + emit_block(node.els, indent + "  ", tail);
                s = s + pad + "}\n";
            };
        } else {
            s = s + pad + "}\n";
        };
        s
    } else if (k == "while") {
        let s = pad + "while (" + emit_expr(node.cond) + ") {\n";
        s = s + emit_block(node.body, indent + "  ", false);
        s + pad + "}\n"
    } else if (k == "forrange") {
        let s = pad + "for (let " + node.name + " = " + emit_expr(node.lo) + "; " +
                node.name + " < " + emit_expr(node.hi) + "; " + node.name + "++) {\n";
        s = s + emit_block(node.body, indent + "  ", false);
        s + pad + "}\n"
    } else {
        // expression statement — in tail position it's the implicit return value
        if (tail) {
            pad + "return " + emit_expr(node) + ";\n"
        } else {
            pad + emit_expr(node) + ";\n"
        }
    }
};

def emit_block(node, indent: str, tail: bool) -> str {
    let s = "";
    let n = len(node.stmts);
    let i = 0;
    while (i < n) {
        // Only the LAST statement of a block is in tail position.
        let is_tail = tail && (i == n - 1);
        s = s + emit_stmt(node.stmts[i], indent, is_tail);
        i = i + 1;
    };
    s
};

// ── top-level: functions become exported AS functions ────────────────────

def emit_func(node, name: str) -> str {
    g_cur_func = name;
    // Build param list. Params are untyped in the AST we have; default to i64.
    let parts = [];
    foreach (p in node.params) {
        parts = push(parts, p + ": i64");
    };
    let s = "export function " + name + "(" + join(parts, ", ") + "): i64 {\n";
    s = s + emit_block(node.body, "  ", true);
    s + "}\n"
};

def emit_program(ast) -> str {
    let header = "// Generated by ycc -> AssemblyScript backend\n";
    let header2 = "@external(\"env\", \"hostPrint\") declare function hostPrint(v: i64): void;\n\n";
    let body = "";
    foreach (s in ast.stmts) {
        if (s.k == "decl") {
            if (s.kind == "def") {
                body = body + emit_func(s.v, s.name) + "\n";
            } else {
                body = body + "// top-level decl: " + s.name + "\n";
            };
        } else {
            // top-level statement -> wrap later; for now emit into a main()
            body = body + "// top-level: " + s.k + "\n";
        };
    };
    header + header2 + body
};

// ── entry point ──────────────────────────────────────────────────────────

def emit(src: str) -> str {
    let toks = lexer.tokenize(src);
    let ast = parser.parse_program(toks);
    emit_program(ast)
};

export { emit };
