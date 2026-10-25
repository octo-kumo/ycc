// Compile-time AST constructors. Locals use the caller's fresh prefix;
// external nodes and types are supplied through its lowering context.
def mq_string(s: str) -> str { "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"" };
def mq_node(kind: str, fields: str = "") -> str {
    "normnode({ k: K." + kind + ", line: q.line, col: q.col" + fields + " })"
};
def mq_name(name: str) -> str { "q.prefix + " + mq_string(name) };
def mq_leaf(kind: str, value: str) -> str { mq_node(kind, ", v: " + mq_string(value)) };
def mq_var(name: str) -> str { mq_node("id", ", v: " + mq_name(name)) };
def mq_block(nodes: [str]) -> str { mq_node("block", ", stmts: [" + join(nodes, ", ") + "]") };
def mq_decl(name: str, typ: str, value: str) -> str {
    mq_node("decl", ", kind: \"let\", name: " + mq_name(name) + ", typ: " + typ + ", v: " + value + ", nline: q.line, ncol: q.col")
};
def mq_set(name: str, value: str) -> str { mq_node("assign", ", name: " + mq_name(name) + ", v: " + value) };
def mq_bin(op: str, l: str, r: str) -> str { mq_node("bin", ", op: " + mq_string(op) + ", l: " + l + ", r: " + r) };
def mq_un(op: str, e: str) -> str { mq_node("un", ", op: " + mq_string(op) + ", e: " + e) };
def mq_call(callee: str, args: [str]) -> str { mq_node("call", ", callee: " + callee + ", args: [" + join(args, ", ") + "]") };
def mq_index(arr: str, idx: str) -> str { mq_node("index", ", arr: " + arr + ", idx: " + idx) };
def mq_put(arr: str, idx: str, value: str) -> str { mq_node("idxassign", ", arr: " + arr + ", idx: " + idx + ", v: " + value) };
def mq_op(op: str, target: str, value: str) -> str { mq_node("opassign", ", op: " + mq_string(op) + ", tgt: " + target + ", v: " + value) };
def mq_loop(cond: str, body: [str]) -> str { mq_node("kw_while", ", cond: " + cond + ", body: " + mq_block(body)) };
def mq_if(cond: str, body: [str]) -> str { mq_node("kw_if", ", cond: " + cond + ", then: " + mq_block(body) + ", els: " + mq_node("void") + ", has_else: false") };
export { mq_node, mq_leaf, mq_var, mq_block, mq_decl, mq_set, mq_bin, mq_un, mq_call, mq_index, mq_put, mq_op, mq_loop, mq_if };
