// check.y — LSP-style semantic checker for Y source code.
// Returns a list of diagnostics: { line, col, severity, message }.
// Severity: "error" | "warning" | "info".
//
// Scopes use the C runtime's native scope builtins (scope_new/scope_def/
// scope_find) so mutations propagate correctly (Y's COW semantics make
// nested-structure mutation on parameters unreliable).

import lexer from "../../ycc/lexer.y";
import parser from "../../ycc/parser.y";

// ── diagnostics ──────────────────────────────────────────────────────────

def mk_diag(line: long, col: long, severity: str, message: str) {
    { line: line, col: col, severity: severity, message: message }
};

// ── AST walker ───────────────────────────────────────────────────────────

def check_expr(node, scope, diags) {
    let k = node.k;
    if (k == "id") {
        if (scope_find(scope, node.v) < 0) {
            diags = push(diags, mk_diag(node.line, node.col, "error", "undefined variable '" + node.v + "'"));
        };
    } else if (k == "bin") {
        diags = check_expr(node.l, scope, diags);
        diags = check_expr(node.r, scope, diags);
    } else if (k == "un") {
        diags = check_expr(node.e, scope, diags);
    } else if (k == "call") {
        diags = check_expr(node.callee, scope, diags);
        foreach (arg in node.args) {
            diags = check_expr(arg, scope, diags);
        };
    } else if (k == "index") {
        diags = check_expr(node.arr, scope, diags);
        diags = check_expr(node.idx, scope, diags);
    } else if (k == "slice") {
        diags = check_expr(node.arr, scope, diags);
        if (node.lo.k != "null") { diags = check_expr(node.lo, scope, diags); };
        if (node.hi.k != "null") { diags = check_expr(node.hi, scope, diags); };
    } else if (k == "dot") {
        diags = check_expr(node.obj, scope, diags);
    } else if (k == "array") {
        foreach (e in node.elems) {
            diags = check_expr(e, scope, diags);
        };
    } else if (k == "map") {
        foreach (v in node.vals) {
            diags = check_expr(v, scope, diags);
        };
    } else if (k == "func") {
        let inner = scope_new(scope);
        foreach (p in node.params) {
            scope_def(inner, p, null);
        };
        diags = check_block(node.body, inner, diags);
    };
    diags
};

def check_stmt(node, scope, diags) {
    let k = node.k;
    if (k == "decl") {
        scope_def(scope, node.name, null);
        diags = check_expr(node.v, scope, diags);
    } else if (k == "assign") {
        if (scope_find(scope, node.name) < 0) {
            diags = push(diags, mk_diag(node.line, node.col, "error", "undefined variable '" + node.name + "'"));
        };
        diags = check_expr(node.v, scope, diags);
    } else if (k == "idxassign") {
        diags = check_expr(node.arr, scope, diags);
        diags = check_expr(node.idx, scope, diags);
        diags = check_expr(node.v, scope, diags);
    } else if (k == "dotassign") {
        diags = check_expr(node.obj, scope, diags);
        diags = check_expr(node.v, scope, diags);
    } else if (k == "ret") {
        diags = check_expr(node.e, scope, diags);
    } else if (k == "if") {
        diags = check_expr(node.cond, scope, diags);
        diags = check_block(node.then, scope_new(scope), diags);
        if (node.has_else) {
            if (node.els.k == "if") {
                diags = check_stmt(node.els, scope, diags);
            } else {
                diags = check_block(node.els, scope_new(scope), diags);
            };
        };
    } else if (k == "while") {
        diags = check_expr(node.cond, scope, diags);
        diags = check_block(node.body, scope_new(scope), diags);
    } else if (k == "foreach") {
        diags = check_expr(node.iter, scope, diags);
        let inner = scope_new(scope);
        scope_def(inner, node.name, null);
        diags = check_block(node.body, inner, diags);
    } else if (k == "forrange") {
        diags = check_expr(node.lo, scope, diags);
        diags = check_expr(node.hi, scope, diags);
        let inner = scope_new(scope);
        scope_def(inner, node.name, null);
        diags = check_block(node.body, inner, diags);
    } else if (k == "for") {
        let inner = scope_new(scope);
        if (node.init.k != "null") { diags = check_stmt(node.init, inner, diags); };
        diags = check_expr(node.cond, inner, diags);
        if (node.step.k != "null") { diags = check_stmt(node.step, inner, diags); };
        diags = check_block(node.body, scope_new(inner), diags);
    } else {
        // expression statement
        diags = check_expr(node, scope, diags);
    };
    diags
};

def check_block(node, scope, diags) {
    foreach (s in node.stmts) {
        diags = check_stmt(s, scope, diags);
    };
    diags
};

// ── entry point ──────────────────────────────────────────────────────────

def check(src: str) {
    let toks = lexer.tokenize(src);
    let ast = parser.parse_program(toks);
    let scope = scope_new(-1);
    // predefine builtins
    foreach (b in ["print", "puts", "len", "substr", "push", "tostring", "tonum", "typeof",
                   "range", "index_of", "arr_index_of", "last_index_of", "ord", "chr",
                   "join", "split", "trim", "map_set", "map_get", "self"]) {
        scope_def(scope, b, null);
    };
    check_block(ast, scope, [])
};

export { check };
