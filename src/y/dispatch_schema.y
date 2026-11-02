// The native emitter's node dispatch, as data. dispatch_codegen.y turns each
// row into an `if` arm; keeping the rows out of the meta block lets the
// compiler-docs tool publish the same table a reader sees in native.y.
//
// Row: KIND[ KIND...]|BINDING: SHAPE|CALL
// The kinds are tags.y's `K` names, the binding is what the arm casts the
// node to, and the call is the handler's body.
const NATIVE_DISPATCH = [
    "num|lit: Leaf|gen_lit(st, lit)",
    "bignum|lit: Leaf|gen_biglit(st, lit)",
    "str|lit: Leaf|gen_str_const(st, lit.v)",
    "bstr|lit: Leaf|gen_bstr(st, lit)",
    "un|un: Un|gen_un(st, un)",
    "addr|addr: Wrap|gen_addr(st, addr)",
    "array|array: ArrLit|gen_array(st, array)",
    "bin|bin: Bin|gen_bin(st, bin)",
    "call|call: Call|gen_call(st, call)",
    "kw_if|branch: If|gen_if(st, branch)",
    "kw_while|loop: While|gen_while(st, loop)",
    "kw_for|loop: For|gen_for(st, loop)",
    "forrange|loop: ForRange|gen_forrange(st, loop)",
    "kw_foreach|loop: Foreach|gen_foreach(st, loop)",
    "block|block: Block|gen_block(st, block)",
    "decl|decl: Decl|gen_decl_marked(st, decl)",
    "assign|assign: Assign|gen_assign(st, assign)",
    "incdec|incdec: IncDec|gen_incdec(st, incdec, false)",
    "opassign|assign: OpAssign|gen_opassign(st, assign, false)",
    "slice|slice: Slice|gen_slice(st, slice)",
    "char|lit: Leaf|gen_lit(st, { k: K.num, v: lit.v, line: lit.line, col: lit.col })",
    "rectest|test: Narrow|gen_rectest(st, test)",
    "sliceassign|assign: SliceAssign|gen_sliceassign(st, assign)",
    "dotassign|assign: DotAssign|gen_dotassign(st, assign)",
    "store|store: Store|gen_store(st, store)",
];
const NATIVE_DISPATCH_OTHERWISE = "gen_special_node(st, node)";
export { NATIVE_DISPATCH, NATIVE_DISPATCH_OTHERWISE };
