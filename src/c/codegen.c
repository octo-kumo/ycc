#define _GNU_SOURCE
#include "codegen.h"
#include "lib.h"
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ── Context ────────────────────────────────────────────────────────────── */

/* Deferred function definitions: collected during expression emission,
 * written out after all expressions are done. This avoids the problem of
 * nested function definitions being interleaved inside outer function bodies. */
typedef struct {
    char **defs;
    size_t count;
    size_t cap;
} FuncQueue;

typedef struct {
    FuncQueue queue;
    int func_id; /* global counter for unique C function names */
} CodegenCtx;

static void fq_init(FuncQueue *q) {
    q->cap = 32;
    q->count = 0;
    q->defs = malloc(sizeof(char *) * q->cap);
}

static void fq_push(FuncQueue *q, char *def) {
    if (q->count >= q->cap) {
        q->cap *= 2;
        q->defs = realloc(q->defs, sizeof(char *) * q->cap);
    }
    q->defs[q->count++] = def;
}

static void fq_free(FuncQueue *q) {
    for (size_t i = 0; i < q->count; i++) free(q->defs[i]);
    free(q->defs);
}

/* ── Helpers ────────────────────────────────────────────────────────────── */

static char *fmt(const char *format, ...) {
    char *buf;
    va_list ap;
    va_start(ap, format);
    if (vasprintf(&buf, format, ap) < 0) {
        fprintf(stderr, "codegen: out of memory\n");
        exit(1);
    }
    va_end(ap);
    return buf;
}

/* Escape a byte string into a C string literal body (no surrounding quotes).
 * Uses octal escapes for non-printable bytes to avoid \x greedy-digit issues. */
static char *escape_c_str(const char *s, size_t len) {
    char *out = malloc(len * 4 + 1);
    size_t j = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '\\': out[j++] = '\\'; out[j++] = '\\'; break;
        case '"':  out[j++] = '\\'; out[j++] = '"';  break;
        case '\n': out[j++] = '\\'; out[j++] = 'n';  break;
        case '\t': out[j++] = '\\'; out[j++] = 't';  break;
        case '\r': out[j++] = '\\'; out[j++] = 'r';  break;
        default:
            if (c < 32 || c > 126)
                j += sprintf(out + j, "\\%03o", c);
            else
                out[j++] = (char)c;
        }
    }
    out[j] = '\0';
    return out;
}

/* Make a string safe for use as a C identifier fragment. */
static char *sanitize_ident(const char *name) {
    char *out = strdup(name);
    for (char *p = out; *p; p++) {
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || *p == '_'))
            *p = '_';
    }
    if (out[0] >= '0' && out[0] <= '9') {
        char *tmp = fmt("_%s", out);
        free(out);
        out = tmp;
    }
    return out;
}

/* ── Forward declarations ───────────────────────────────────────────────── */

static char *emit_expr(CodegenCtx *ctx, Expr *expr);
static char *emit_while(CodegenCtx *ctx, EWhile *w);
static char *emit_for(CodegenCtx *ctx, EFor *f);
static char *emit_foreach(CodegenCtx *ctx, EForEach *fe);
static char *emit_forrange(CodegenCtx *ctx, EForRange *fr);

/* ── Function definition emission ───────────────────────────────────────── */

/* Emit a complete C function definition into the deferred queue.
 * Returns the C function name (malloc'd, caller frees).
 * Each call gets a globally unique name via ctx->func_id. */
static char *emit_func_def(CodegenCtx *ctx, EFunc *func, const char *hint) {
    char *safe = sanitize_ident(hint);
    char *cname = fmt("yfn_%s_%d", safe, ctx->func_id++);
    free(safe);

    /* Build the function body into a string buffer */
    char *body_buf;
    size_t body_len;
    FILE *f = open_memstream(&body_buf, &body_len);

    fprintf(f, "static YValue *%s(YScope *closure, YValue **args, size_t argc) {\n", cname);
    /* Arity check, as the VM does before binding parameters: without it a
     * short call reads args[] past the end and the binary segfaults (the
     * typechecker is advisory, so it cannot stop codegen on its own). */
    fprintf(f, "    if (argc != %zu) {\n", func->param_count);
    fprintf(f, "        fprintf(stderr, \"Argument count mismatch in function call\\n\");\n");
    fprintf(f, "        exit(1);\n");
    fprintf(f, "    }\n");
    fprintf(f, "    (void)argc;\n");
    fprintf(f, "    YScope *scope = malloc(sizeof(YScope));\n");
    fprintf(f, "    y_scope_init(scope, closure);\n");

    for (size_t i = 0; i < func->param_count; i++) {
        fprintf(f, "    y_scope_set(scope, \"%s\", args[%zu]);\n",
                func->param_names[i], i);
        fprintf(f, "    args[%zu] = NULL; /* transfer ownership to scope */\n", i);
    }

    /* self-reference for recursion (local-only: don't clobber a parent's
     * self). A parameter named `self` is the programmer's, so leave it. */
    int self_is_param = 0;
    for (size_t i = 0; i < func->param_count; i++)
        if (strcmp(func->param_names[i], "self") == 0) self_is_param = 1;
    if (!self_is_param)
        fprintf(f, "    y_scope_set_local(scope, \"self\", y_mk_func(%s, %zu, closure));\n",
                cname, func->param_count);

    /* Early `return`: statements jump to _yret_lbl with the value in _yret.
     * Both are declared up front so a jump can never skip an initializer. */
    fprintf(f, "    YValue *_yret = NULL;\n");
    fprintf(f, "    YValue *_result = NULL;\n");

    /* Emit function body. If it's a block, emit statements directly into the
     * parameter scope (not a nested block scope) so closures capture a scope
     * that lives as long as the function value. */
    if (func->body->kind == EXPR_EBLOCK) {
        EBlock *blk = &func->body->as.block_node;
        for (size_t i = 0; i < blk->count; i++) {
            char *stmt = emit_expr(ctx, blk->exprs[i]);
            if (i + 1 == blk->count) {
                /* Last statement: its value is the return value */
                fprintf(f, "    _result = %s;\n", stmt);
            } else {
                /* Non-final statement: free its value */
                fprintf(f, "    y_free((YValue *)(%s));\n", stmt);
            }
            free(stmt);
        }
    } else {
        /* Non-block body: single expression */
        char *body = emit_expr(ctx, func->body);
        fprintf(f, "    _result = %s;\n", body);
        free(body);
    }
    /* _result is a fresh owned value (not stored in the scope), so return it
     * directly. Releasing the scope first frees params/locals/closures without
     * touching _result. An empty body leaves both NULL -> null, like the VM. */
    fprintf(f, "_yret_lbl: ;\n");
    fprintf(f, "    y_scope_release(scope);\n");
    fprintf(f, "    if (_yret) { y_free(_result); return _yret; }\n");
    fprintf(f, "    return _result ? _result : y_mk_null();\n");
    fprintf(f, "}\n\n");

    fclose(f);

    /* Defer: the definition is appended to the queue AFTER any nested
     * function definitions that emit_expr may have pushed. We insert
     * at the current position so nested defs come first (they must be
     * defined before the outer function references them). */
    /* Actually, we need nested defs to appear BEFORE the outer function.
     * Since emit_expr already pushed nested defs into the queue, we just
     * append this one after them. */
    fq_push(&ctx->queue, body_buf);

    return cname;
}

/* ── Operator mapping ───────────────────────────────────────────────────── */

static const char *op_fn(Operator op) {
    switch (op) {
    case O_ADD:  return "y_add";
    case O_SUB:  return "y_sub";
    case O_MUL:  return "y_mul";
    case O_DIV:  return "y_div";
    case O_MOD:  return "y_mod";
    case O_LT:   return "y_lt";
    case O_GT:   return "y_gt";
    case O_LTE:  return "y_lte";
    case O_GTE:  return "y_gte";
    case O_EQ:   return "y_eq";
    case O_NEQ:  return "y_neq";
    case O_AND:  return "y_and";
    case O_OR:   return "y_or";
    case O_CONS: return "y_cons";
    default:     return NULL;
    }
}

/* ── Expression emission ────────────────────────────────────────────────── */

/* Does this expression tree contain a reference to variable `name`?
 * Used to guard the y_scope_take optimization: we can only move a variable
 * out of scope before evaluating the RHS if the RHS doesn't read it. */
static bool expr_references_var(Expr *expr, const char *name) {
    if (!expr) return false;
    switch (expr->kind) {
    case EXPR_EVAR:
        return strcmp(expr->as.evar, name) == 0;
    case EXPR_EOP:
        return expr_references_var(expr->as.op_node.left, name) ||
               expr_references_var(expr->as.op_node.right, name);
    case EXPR_EUNARY:
        return expr_references_var(expr->as.unary_node.operand, name);
    case EXPR_ECALL:
        if (expr_references_var(expr->as.call_node.callee, name)) return true;
        for (size_t i = 0; i < expr->as.call_node.arg_count; i++)
            if (expr_references_var(expr->as.call_node.args[i], name)) return true;
        return false;
    case EXPR_EARRAY:
        for (size_t i = 0; i < expr->as.array_node.count; i++)
            if (expr_references_var(expr->as.array_node.elements[i], name)) return true;
        return false;
    case EXPR_EARRAY_IDX:
        return expr_references_var(expr->as.array_idx_node.array, name) ||
               expr_references_var(expr->as.array_idx_node.idx, name);
    case EXPR_EARRAY_IDX_RANGE:
        return expr_references_var(expr->as.array_idx_range_node.array, name) ||
               expr_references_var(expr->as.array_idx_range_node.start, name) ||
               expr_references_var(expr->as.array_idx_range_node.end, name);
    case EXPR_EMAP:
        for (size_t i = 0; i < expr->as.map_node.count; i++)
            if (expr_references_var(expr->as.map_node.entries[i].value, name)) return true;
        return false;
    case EXPR_EIF:
        return expr_references_var(expr->as.if_node.cond, name) ||
               expr_references_var(expr->as.if_node.then_branch, name) ||
               expr_references_var(expr->as.if_node.else_branch, name);
    case EXPR_EBLOCK:
        for (size_t i = 0; i < expr->as.block_node.count; i++)
            if (expr_references_var(expr->as.block_node.exprs[i], name)) return true;
        return false;
    default:
        return false;  /* literals, null, etc. */
    }
}

/* Returns a malloc'd C expression string of type (YValue *).
 * The returned value is always OWNED by the caller. */
static char *emit_expr(CodegenCtx *ctx, Expr *expr) {
    switch (expr->kind) {

    case EXPR_ELONG:
        return fmt("y_mk_long(%ldL)", expr->as.elong);

    case EXPR_EFLOAT:
        return fmt("y_mk_float(%.17g)", expr->as.efloat);

    case EXPR_EBOOL:
        return fmt("y_mk_bool(%d)", expr->as.ebool ? 1 : 0);

    case EXPR_ENULL:
        return fmt("y_mk_null()");

    case EXPR_ESTR: {
        char *esc = escape_c_str(expr->as.estr.data, (size_t)expr->as.estr.length);
        char *r = fmt("y_mk_str_n(\"%s\", %d)", esc, expr->as.estr.length);
        free(esc);
        return r;
    }

    case EXPR_EVAR:
        return fmt("y_clone(y_scope_get(scope, \"%s\"))", expr->as.evar);

    case EXPR_EUNARY: {
        char *operand = emit_expr(ctx, expr->as.unary_node.operand);
        char *res;
        if (expr->as.unary_node.op == O_NOT) {
            res = fmt(
                "({ YValue *_u = %s; "
                "if (_u->type != Y_BOOL) { fprintf(stderr, \"runtime error: '!' requires bool\\n\"); exit(1); } "
                "YValue *_r = y_mk_bool(!_u->data.b); y_free(_u); _r; })",
                operand);
        } else {
            res = fmt("y_neg(%s)", operand);
        }
        free(operand);
        return res;
    }
    case EXPR_ERETURN: {
        /* Early return: stash the value and jump to the function epilogue,
         * which releases the scope and hands _yret back. Jumping out of a
         * statement expression is legal in GNU C; enclosing block scopes
         * are not released on that path (they leak, they never dangle). */
        char *val = expr->as.return_value
                        ? emit_expr(ctx, expr->as.return_value)
                        : fmt("y_mk_null()");
        char *r = fmt("({ _yret = %s; goto _yret_lbl; (YValue *)NULL; })", val);
        free(val);
        return r;
    }
    case EXPR_EOP: {
        if (expr->as.op_node.op == O_DOT) {
            char *left = emit_expr(ctx, expr->as.op_node.left);
            if (expr->as.op_node.right &&
                expr->as.op_node.right->kind == EXPR_EVAR) {
                const char *key = expr->as.op_node.right->as.evar;
                char *r = fmt(
                    "({ YValue *_m = %s; "
                    "YValue *_v = y_map_get(_m, \"%s\"); "
                    "if (!_v) { fprintf(stderr, \"runtime error: key '%s' not found\\n\"); exit(1); } "
                    "YValue *_r = y_clone(_v); y_free(_m); _r; })",
                    left, key, key);
                free(left);
                return r;
            }
            free(left);
            return fmt("y_mk_null()");
        }

        /* Short-circuit: emit a conditional so the right operand is only
         * evaluated when the left does not already decide the result
         * (matching the VM). y_and/y_or stay for nothing else to use. */
        if (expr->as.op_node.op == O_AND || expr->as.op_node.op == O_OR) {
            char *l = emit_expr(ctx, expr->as.op_node.left);
            char *r = emit_expr(ctx, expr->as.op_node.right);
            int is_and = expr->as.op_node.op == O_AND;
            char *res = fmt(
                "({ YValue *_l = %s; "
                "if (_l->type != Y_BOOL) { fprintf(stderr, \"runtime error: '%s' requires bool\\n\"); exit(1); } "
                "bool _lb = _l->data.b; y_free(_l); YValue *_r; "
                "if (%s_lb) { _r = y_mk_bool(_lb); } else { "
                "YValue *_rv = %s; "
                "if (_rv->type != Y_BOOL) { fprintf(stderr, \"runtime error: '%s' requires bool\\n\"); exit(1); } "
                "_r = y_mk_bool(_rv->data.b); y_free(_rv); } _r; })",
                l, is_and ? "&&" : "||", is_and ? "!" : "", r,
                is_and ? "&&" : "||");
            free(l);
            free(r);
            return res;
        }

        const char *fn = op_fn(expr->as.op_node.op);
        if (!fn) {
            fprintf(stderr, "codegen: unsupported operator %d\n",
                    expr->as.op_node.op);
            return fmt("y_mk_null()");
        }
        char *l = emit_expr(ctx, expr->as.op_node.left);
        char *r = emit_expr(ctx, expr->as.op_node.right);
        char *res = fmt("%s(%s, %s)", fn, l, r);
        free(l);
        free(r);
        return res;
    }

    case EXPR_EIF: {
        char *c  = emit_expr(ctx, expr->as.if_node.cond);
        char *tb = emit_expr(ctx, expr->as.if_node.then_branch);
        char *eb = expr->as.if_node.else_branch
                       ? emit_expr(ctx, expr->as.if_node.else_branch)
                       : fmt("y_mk_null()");
        char *r = fmt(
            "({ YValue *_c = %s; bool _cb = _c->data.b; y_free(_c); YValue *_r; "
            "if (_cb) { _r = %s; } else { _r = %s; } _r; })",
            c, tb, eb);
        free(c); free(tb); free(eb);
        return r;
    }

    case EXPR_EBLOCK: {
        /* An empty block has no statement to define _r, and the trailing
         * `_r;` would then resolve to an enclosing (uninitialized) _r --
         * e.g. the `_r` of a surrounding if -- which the caller then frees.
         * `if (true) {}` aborted with "double free or corruption" for
         * exactly this reason. An empty block evaluates to null, matching
         * the VM. */
        if (expr->as.block_node.count == 0)
            return fmt("({ YScope *_outer = scope; "
                       "YScope *scope = malloc(sizeof(YScope)); "
                       "y_scope_init(scope, _outer); "
                       "y_scope_release(scope); y_mk_null(); })");
        char *body = fmt("");
        for (size_t i = 0; i < expr->as.block_node.count; i++) {
            char *stmt = emit_expr(ctx, expr->as.block_node.exprs[i]);
            char *next;
            if (i + 1 == expr->as.block_node.count)
                next = fmt("%s YValue *_r = %s;", body, stmt);
            else
                /* Non-final statement: its value is discarded, so free it
                 * to avoid leaking every intermediate result in a block. */
                next = fmt("%s y_free((YValue *)(%s));", body, stmt);
            free(body);
            free(stmt);
            body = next;
        }
        char *r = fmt(
            "({ YScope *_outer = scope; "
            "YScope *scope = malloc(sizeof(YScope)); "
            "y_scope_init(scope, _outer);%s y_scope_release(scope); _r; })",
            body);
        free(body);
        return r;
    }

    case EXPR_EDECLARATION: {
        /* Named function declaration.
         * Wrap in a statement expression that yields a YValue (null) so it
         * can be uniformly y_free'd when used as a non-final block statement. */
        if (expr->as.declaration_node.kind == DECL_FUNC &&
            expr->as.declaration_node.value &&
            expr->as.declaration_node.value->kind == EXPR_EFUNC) {
            EFunc *fn = &expr->as.declaration_node.value->as.efunc;
            char *cname = emit_func_def(ctx, fn, expr->as.declaration_node.name);
            char *r = fmt("({ y_scope_set_local(scope, \"%s\", y_mk_func(%s, %zu, scope)); y_mk_null(); })",
                          expr->as.declaration_node.name, cname, fn->param_count);
            free(cname);
            return r;
        }
        /* let / const binding */
        char *val = emit_expr(ctx, expr->as.declaration_node.value);
        char *r = fmt(
            "({ YValue *_v = %s; y_scope_set_local(scope, \"%s\", _v); y_clone(_v); })",
            val, expr->as.declaration_node.name);
        free(val);
        return r;
    }

    case EXPR_EASSIGNMENT: {
        const char *var_name = expr->as.assignment_node.var_name;
        Expr *val_expr = expr->as.assignment_node.value;

        /* Optimize 'name = push(name, ...)' with y_scope_take to avoid the
         * O(n) COW deep-copy that scope_get's clone would otherwise trigger.
         * Only safe when the pushed value (arg1) does NOT reference 'name' —
         * otherwise taking it out of scope first would break the read
         * (e.g. 'c = push(c, c[0])' would index a null placeholder). */
        if (val_expr->kind == EXPR_ECALL &&
            val_expr->as.call_node.callee->kind == EXPR_EVAR &&
            strcmp(val_expr->as.call_node.callee->as.evar, "push") == 0 &&
            val_expr->as.call_node.arg_count == 2 &&
            val_expr->as.call_node.args[0]->kind == EXPR_EVAR &&
            strcmp(val_expr->as.call_node.args[0]->as.evar, var_name) == 0 &&
            !expr_references_var(val_expr->as.call_node.args[1], var_name)) {
            char *arg1 = emit_expr(ctx, val_expr->as.call_node.args[1]);
            char *r = fmt(
                "({ YValue *_arr = y_scope_take(scope, \"%s\"); "
                "if (!_arr) _arr = y_clone(y_scope_get(scope, \"%s\")); "
                "YValue *_a[] = { _arr, %s }; "
                "YValue *_fn = y_clone(y_scope_get(scope, \"push\")); "
                "YValue *_v = y_call(_fn, _a, 2); y_free(_fn); "
                "y_scope_set(scope, \"%s\", _v); y_clone(_v); })",
                var_name, var_name, arg1, var_name);
            free(arg1);
            return r;
        }

        char *val = emit_expr(ctx, val_expr);
        char *r = fmt(
            "({ YValue *_v = %s; y_scope_set(scope, \"%s\", _v); y_clone(_v); })",
            val, var_name);
        free(val);
        return r;
    }

    case EXPR_ECALL: {
        /* Method-style call m.f(args): the C parser reads `f().y` shapes
         * as field access, but the module system generates m.f(...) for
         * every imported function — resolve the field at runtime. */
        if (expr->as.call_node.callee->kind == EXPR_EOP &&
            expr->as.call_node.callee->as.op_node.op == O_DOT &&
            expr->as.call_node.callee->as.op_node.right &&
            expr->as.call_node.callee->as.op_node.right->kind ==
                EXPR_EVAR) {
            char *left = emit_expr(ctx, expr->as.call_node.callee->as.op_node.left);
            const char *key = expr->as.call_node.callee->as.op_node.right->as.evar;
            char *args = fmt("");
            for (size_t i = 0; i < expr->as.call_node.arg_count; i++) {
                char *a = emit_expr(ctx, expr->as.call_node.args[i]);
                char *next = fmt("%s %s,", args, a);
                free(args);
                free(a);
                args = next;
            }
            char *free_args = fmt("");
            for (size_t i = 0; i < expr->as.call_node.arg_count; i++) {
                char *next = fmt("%s y_free(_a[%zu]);", free_args, i);
                free(free_args);
                free_args = next;
            }
            char *r = fmt("({ YValue *_m = %s; YValue *_v = y_map_get(_m, \"%s\"); "
                          "if (!_v || _v->type != Y_FUNC) { fprintf(stderr, \"runtime error: '%%s' is not a function\\n\", \"%s\"); exit(1); } "
                          "YValue *_a[] = {%s}; YValue *_fn = y_clone(_v); YValue *_r = y_call(_fn, _a, %zu); "
                          "y_free(_fn); y_free(_m);%s _r; })",
                          left, key, key, args, expr->as.call_node.arg_count, free_args);
            free(args);
            free(left);
            free(free_args);
            return r;
        }
        char *callee = emit_expr(ctx, expr->as.call_node.callee);
        if (expr->as.call_node.arg_count == 0) {
            /* free the (cloned) callee after the call to avoid leaking it */
            char *r = fmt("({ YValue *_fn = %s; YValue *_r = y_call(_fn, NULL, 0); y_free(_fn); _r; })", callee);
            free(callee);
            return r;
        }
        char *args = fmt("");
        for (size_t i = 0; i < expr->as.call_node.arg_count; i++) {
            char *a = emit_expr(ctx, expr->as.call_node.args[i]);
            char *next = fmt("%s %s,", args, a);
            free(args);
            free(a);
            args = next;
        }
        /* Free the (cloned) callee and all arguments after the call.
         * Builtins that keep an argument (e.g. push keeps args[1]) must set
         * that slot to NULL so it isn't double-freed here. */
        char *free_args = fmt("");
        for (size_t i = 0; i < expr->as.call_node.arg_count; i++) {
            char *next = fmt("%s y_free(_a[%zu]);", free_args, i);
            free(free_args);
            free_args = next;
        }
        char *r = fmt("({ YValue *_a[] = {%s}; YValue *_fn = %s; YValue *_r = y_call(_fn, _a, %zu); y_free(_fn);%s _r; })",
                      args, callee, expr->as.call_node.arg_count, free_args);
        free(args);
        free(callee);
        free(free_args);
        return r;
    }

    case EXPR_EFUNC: {
        char *name = fmt("anon_%d", ctx->func_id);
        char *cname = emit_func_def(ctx, &expr->as.efunc, name);
        free(name);
        char *r = fmt("y_mk_func(%s, %zu, scope)", cname,
                      expr->as.efunc.param_count);
        free(cname);
        return r;
    }

    case EXPR_EARRAY: {
        if (expr->as.array_node.count == 0)
            return fmt("y_mk_arr(NULL, 0)");
        char *elems = fmt("");
        for (size_t i = 0; i < expr->as.array_node.count; i++) {
            char *e = emit_expr(ctx, expr->as.array_node.elements[i]);
            char *next = fmt("%s %s,", elems, e);
            free(elems);
            free(e);
            elems = next;
        }
        char *r = fmt("({ YValue *_e[] = {%s}; y_mk_arr(_e, %zu); })",
                      elems, expr->as.array_node.count);
        free(elems);
        return r;
    }

    case EXPR_EARRAY_IDX: {
        char *arr = emit_expr(ctx, expr->as.array_idx_node.array);
        char *idx = emit_expr(ctx, expr->as.array_idx_node.idx);
        char *r = fmt("y_arr_index(%s, %s)", arr, idx);
        free(arr);
        free(idx);
        return r;
    }

    case EXPR_EARRAY_IDX_RANGE: {
        char *arr = emit_expr(ctx, expr->as.array_idx_range_node.array);
        char *s   = emit_expr(ctx, expr->as.array_idx_range_node.start);
        char *e   = emit_expr(ctx, expr->as.array_idx_range_node.end);
        char *r = fmt("y_arr_slice(%s, %s, %s)", arr, s, e);
        free(arr); free(s); free(e);
        return r;
    }

    case EXPR_EMAP: {
        if (expr->as.map_node.count == 0)
            return fmt("y_mk_map(NULL, 0)");
        /* Spread (`{a: 1, ...b}`) needs entries the compiler cannot lay out
         * statically, so build the map incrementally in that case. */
        int has_spread = 0;
        for (size_t i = 0; i < expr->as.map_node.count; i++)
            if (!expr->as.map_node.entries[i].key) has_spread = 1;
        if (has_spread) {
            char *body = fmt("");
            for (size_t i = 0; i < expr->as.map_node.count; i++) {
                char *v = emit_expr(ctx, expr->as.map_node.entries[i].value);
                char *next;
                if (expr->as.map_node.entries[i].key)
                    next = fmt("%s y_map_put(_m, \"%s\", %s);", body,
                               expr->as.map_node.entries[i].key, v);
                else
                    next = fmt("%s y_map_merge(_m, %s);", body, v);
                free(body);
                free(v);
                body = next;
            }
            char *r = fmt("({ YValue *_m = y_mk_map(NULL, 0);%s _m; })", body);
            free(body);
            return r;
        }
        char *entries = fmt("");
        for (size_t i = 0; i < expr->as.map_node.count; i++) {
            char *v = emit_expr(ctx, expr->as.map_node.entries[i].value);
            char *next = fmt("%s {\"%s\", %s},", entries,
                             expr->as.map_node.entries[i].key, v);
            free(entries);
            free(v);
            entries = next;
        }
        char *r = fmt("({ YMapEntry _e[] = {%s}; y_mk_map(_e, %zu); })",
                      entries, expr->as.map_node.count);
        free(entries);
        return r;
    }

    case EXPR_EWHILE: return emit_while(ctx, &expr->as.while_node);
    case EXPR_EFOR: return emit_for(ctx, &expr->as.for_node);
    case EXPR_EFOREACH: return emit_foreach(ctx, &expr->as.foreach_node);
    case EXPR_EFORRANGE: return emit_forrange(ctx, &expr->as.forrange_node);

    case EXPR_EARRAY_ASSIGN: {
        /* arr[i] = val  →  mutate the array in scope */
        char *arr = emit_expr(ctx, expr->as.array_assign_node.array);
        char *idx = emit_expr(ctx, expr->as.array_assign_node.idx);
        char *val = emit_expr(ctx, expr->as.array_assign_node.value);
        char *r;
        if (expr->as.array_assign_node.array->kind == EXPR_EVAR) {
            /* Variable target: get from scope, mutate, write back */
            r = fmt(
                "({ YValue *_a = y_scope_get(scope, \"%s\"); "
                "YValue *_i = %s; YValue *_v = %s; "
                "y_arr_set(_a, _i, _v); y_mk_null(); })",
                expr->as.array_assign_node.array->as.evar, idx, val);
        } else {
            r = fmt(
                "({ YValue *_a = %s; YValue *_i = %s; YValue *_v = %s; "
                "y_arr_set(_a, _i, _v); y_mk_null(); })",
                arr, idx, val);
        }
        free(arr); free(idx); free(val);
        return r;
    }

    default:
        fprintf(stderr, "codegen: unsupported expr kind %d\n", expr->kind);
        return fmt("y_mk_null()");
    }
}

/* ── Loop statement emission ────────────────────────────────────────────── */

/* Loops are statements, not expressions. They execute for side effects
 * and return the last body value (or null). We emit them as GCC statement
 * expressions containing C loops. */

static char *emit_while(CodegenCtx *ctx, EWhile *w) {
    char *c = emit_expr(ctx, w->cond);
    char *b = emit_expr(ctx, w->body);
    /* Free the condition result every iteration (including the break
     * iteration) to avoid leaking one bool per loop pass. */
    char *r = fmt(
        "({ YValue *_last = y_mk_null(); "
        "while (1) { YValue *_c = %s; bool _cb = _c->data.b; y_free(_c); if (!_cb) break; "
        "y_free(_last); _last = %s; } _last; })",
        c, b);
    free(c); free(b);
    return r;
}

static char *emit_for(CodegenCtx *ctx, EFor *f) {
    char *init = f->init ? emit_expr(ctx, f->init) : NULL;
    char *cond = f->cond ? emit_expr(ctx, f->cond) : NULL;
    char *step = f->step ? emit_expr(ctx, f->step) : NULL;
    char *body = emit_expr(ctx, f->body);

    /* Build the loop body piece by piece */
    char *r = fmt(
        "({ YScope *_outer = scope; "
        "YScope *scope = malloc(sizeof(YScope)); "
        "y_scope_init(scope, _outer); ");
    if (init) {
        /* init value is discarded — free it (the scope keeps its own copy) */
        char *next = fmt("%sy_free((YValue *)(%s)); ", r, init);
        free(r); r = next;
    }
    char *next = fmt("%sYValue *_last = y_mk_null(); while (1) { ", r);
    free(r); r = next;
    if (cond) {
        /* free the condition result every iteration to avoid a per-iter leak */
        next = fmt("%sYValue *_c = %s; bool _cb = _c->data.b; y_free(_c); if (!_cb) break; ", r, cond);
        free(r); r = next;
    }
    next = fmt("%sy_free(_last); _last = %s; ", r, body);
    free(r); r = next;
    if (step) {
        /* step value is discarded — free it */
        next = fmt("%sy_free((YValue *)(%s)); ", r, step);
        free(r); r = next;
    }
    next = fmt("%s} y_scope_release(scope); _last; })", r);
    free(r); r = next;

    free(init); free(cond); free(step); free(body);
    return r;
}

static char *emit_foreach(CodegenCtx *ctx, EForEach *fe) {
    char *iter = emit_expr(ctx, fe->iterable);
    char *body = emit_expr(ctx, fe->body);
    char *r = fmt(
        "({ YValue *_arr = %s; "
        "YScope *_outer = scope; "
        "YScope *scope = malloc(sizeof(YScope)); "
        "y_scope_init(scope, _outer); "
        "YValue *_last = y_mk_null(); "
        "for (size_t _i = 0; _i < _arr->data.arr->count; _i++) { "
        "y_scope_set(scope, \"%s\", y_clone(_arr->data.arr->elements[_i])); "
        "y_free(_last); _last = %s; } y_scope_release(scope); _last; })",
        iter, fe->var_name, body);
    free(iter); free(body);
    return r;
}

static char *emit_forrange(CodegenCtx *ctx, EForRange *fr) {
    char *s = emit_expr(ctx, fr->start);
    char *e = emit_expr(ctx, fr->end);
    char *body = emit_expr(ctx, fr->body);
    char *r = fmt(
        "({ YValue *_sv = %s; YValue *_ev = %s; "
        "long _s = _sv->data.l; long _e = _ev->data.l; "
        "y_free(_sv); y_free(_ev); "
        "YScope *_outer = scope; "
        "YScope *scope = malloc(sizeof(YScope)); "
        "y_scope_init(scope, _outer); "
        "YValue *_last = y_mk_null(); "
        "for (long _i = _s; _i < _e; _i++) { "
        "y_scope_set(scope, \"%s\", y_mk_long(_i)); "
        "y_free(_last); _last = %s; } y_scope_release(scope); _last; })",
        s, e, fr->var_name, body);
    free(s); free(e); free(body);
    return r;
}

/* ── Public API ─────────────────────────────────────────────────────────── */

int codegen_emit(Expr *ast, FILE *out) {
    CodegenCtx ctx = {0};
    fq_init(&ctx.queue);

    /* Buffer for main body */
    char *main_buf;
    size_t main_len;
    FILE *main_stream = open_memstream(&main_buf, &main_len);
    if (!main_stream) {
        perror("codegen: open_memstream");
        fq_free(&ctx.queue);
        return 1;
    }

    /* Emit top-level statements (this populates ctx.queue with func defs) */
    if (ast->kind == EXPR_EBLOCK) {
        for (size_t i = 0; i < ast->as.block_node.count; i++) {
            char *s = emit_expr(&ctx, ast->as.block_node.exprs[i]);
            /* Free the value yielded by each top-level statement */
            fprintf(main_stream, "    y_free((YValue *)(%s));\n", s);
            free(s);
        }
    } else {
        char *s = emit_expr(&ctx, ast);
        fprintf(main_stream, "    y_free((YValue *)(%s));\n", s);
        free(s);
    }

    fclose(main_stream);

    /* Assemble final output */
    fprintf(out, "/* Generated by y compiler — C backend */\n");
    fprintf(out, "#include \"runtime.h\"\n\n");

    /* Write all deferred function definitions (nested defs come before
     * their parents because emit_func_def appends after emit_expr
     * has already pushed nested defs). */
    if (ctx.queue.count > 0) {
        fprintf(out, "/* ── function definitions ── */\n\n");
        for (size_t i = 0; i < ctx.queue.count; i++)
            fputs(ctx.queue.defs[i], out);
    }

    fprintf(out, "/* ── entry point ── */\n\n");
    fprintf(out, "int main(int argc, char **argv) {\n");
    fprintf(out, "    y_set_argv(argc, argv);\n");
    fprintf(out, "    YScope *scope = malloc(sizeof(YScope));\n");
    fprintf(out, "    y_scope_init(scope, NULL);\n\n");
    fprintf(out, "    /* builtins */\n");
    fprintf(out, "    y_scope_set(scope, \"print\",    y_mk_func(y_builtin_print,    1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"tostring\", y_mk_func(y_builtin_tostring, 1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"typeof\",   y_mk_func(y_builtin_typeof,   1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"range\",    y_mk_func(y_builtin_range,    1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"readline\", y_mk_func(y_builtin_readline, 0, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"puts\",     y_mk_func(y_builtin_puts,     1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"exit\",     y_mk_func(y_builtin_exit,     1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"split\",    y_mk_func(y_builtin_split,    2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"len\",      y_mk_func(y_builtin_len,      1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"trim\",     y_mk_func(y_builtin_trim,     1, NULL));\n");
    if (!g_exec_disabled)
        fprintf(out, "    y_scope_set(scope, \"exec\",     y_mk_func(y_builtin_exec,     1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"argv\",     y_mk_func(y_builtin_argv,     0, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"tonum\",    y_mk_func(y_builtin_tonum,    1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"join\",     y_mk_func(y_builtin_join,     2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"push\",     y_mk_func(y_builtin_push,     2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"substr\",   y_mk_func(y_builtin_substr,   3, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"read_file\", y_mk_func(y_builtin_read_file, 1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"some\", y_mk_func(y_builtin_some, 1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"is_some\", y_mk_func(y_builtin_is_some, 1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"unwrap\", y_mk_func(y_builtin_unwrap, 1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"write_file\", y_mk_func(y_builtin_write_file, 2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"write_bytes\", y_mk_func(y_builtin_write_bytes, 3, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"ord\",      y_mk_func(y_builtin_ord,      1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"chr\",      y_mk_func(y_builtin_chr,      1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"clear_eof\", y_mk_func(y_builtin_clear_eof, 0, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"bytes\",    y_mk_func(y_builtin_bytes,    1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"from_bytes\", y_mk_func(y_builtin_from_bytes, 1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"bytes_to_str\", y_mk_func(y_builtin_bytes_to_str, 1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"ensure_runtime\", y_mk_func(y_builtin_ensure_runtime, 0, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"gen_embedded_runtime\", y_mk_func(y_builtin_gen_embedded_runtime, 2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"index_of\", y_mk_func(y_builtin_index_of, 2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"arr_index_of\", y_mk_func(y_builtin_arr_index_of, 2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"last_index_of\", y_mk_func(y_builtin_last_index_of, 2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"getenv\",   y_mk_func(y_builtin_getenv,   1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"tcp_listen\", y_mk_func(y_builtin_tcp_listen, 1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"tcp_accept\", y_mk_func(y_builtin_tcp_accept, 1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"tcp_read\",   y_mk_func(y_builtin_tcp_read,   2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"tcp_write\",  y_mk_func(y_builtin_tcp_write,  2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"tcp_close\",  y_mk_func(y_builtin_tcp_close,  1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"map_set\",  y_mk_func(y_builtin_map_set,  3, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"map_get\",  y_mk_func(y_builtin_map_get,  2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"global_get\", y_mk_func(y_builtin_global_get, 1, scope));\n");
    fprintf(out, "    y_scope_set(scope, \"scope_new\", y_mk_func(y_builtin_scope_new, 1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"scope_def\", y_mk_func(y_builtin_scope_def, 3, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"scope_find\", y_mk_func(y_builtin_scope_find, 2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"scope_get\", y_mk_func(y_builtin_scope_get, 2, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"scope_set\", y_mk_func(y_builtin_scope_set, 3, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"eputs\",    y_mk_func(y_builtin_eputs,    1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"sleep\",     y_mk_func(y_builtin_sleep,     1, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"clock_us\", y_mk_func(y_builtin_clock_us, 0, NULL));\n");
    fprintf(out, "    y_scope_set(scope, \"heap_used\", y_mk_func(y_builtin_heap_used, 0, NULL));\n\n");
    /* A top-level `return` stops the program, matching the VM (which stops
     * executing statements once the return flag is set). */
    fprintf(out, "    YValue *_yret = NULL;\n");
    fwrite(main_buf, 1, main_len, out);
    fprintf(out, "\n_yret_lbl: ;\n");
    fprintf(out, "    y_free(_yret);\n");
    fprintf(out, "    y_scope_release(scope);\n");
    fprintf(out, "    return 0;\n");
    fprintf(out, "}\n");

    free(main_buf);
    fq_free(&ctx.queue);
    return 0;
}

#ifndef RUNTIME_DIR
#define RUNTIME_DIR "."
#endif

int codegen_compile(Expr *ast, const char *output_path) {
    char tmpdir[] = "/tmp/ycompile_XXXXXX";
    if (!mkdtemp(tmpdir)) {
        perror("codegen: mkdtemp");
        return 1;
    }

    char c_path[512];
    snprintf(c_path, sizeof(c_path), "%s/program.c", tmpdir);
    FILE *f = fopen(c_path, "w");
    if (!f) {
        perror("codegen: fopen");
        return 1;
    }
    codegen_emit(ast, f);
    fclose(f);

    char cmd[2048];
    snprintf(cmd, sizeof(cmd),
             "cc -O2 -std=gnu99 -I'%s' -o '%s' '%s' '%s/runtime.c' -lm 2>&1",
             RUNTIME_DIR, output_path, c_path, RUNTIME_DIR);

    printf("[codegen] compiling → %s\n", output_path);
    int ret = system(cmd);

    if (ret != 0) {
        fprintf(stderr, "[codegen] compilation failed (exit %d)\n", ret);
        fprintf(stderr, "[codegen] C source kept at: %s\n", c_path);
        return 1;
    }

    printf("[codegen] success: %s\n", output_path);
    printf("[codegen] C source: %s\n", c_path);
    return 0;
}
