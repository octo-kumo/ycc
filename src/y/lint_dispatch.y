#{
    import taggen from "./dispatch_codegen.y";
    taggen.meta_tag_dispatch("lint_node(st: LintSt, node: Node, used: bool) -> void", [
        "id|leaf: Leaf|lint_id(st, leaf, used)",
        "bin|bin: Bin|lint_bin(st, bin, used)",
        "decl|decl: Decl|lint_decl(st, decl)",
        "block|block: Block|lint_stmts(st, block.stmts, used, false)",
        "kw_if|branch: If|lint_if(st, branch, used)",
        "assign|assign: Assign|lint_assign(st, assign)",
        "opassign|opassign: OpAssign|lint_opassign(st, opassign, used)",
        "incdec|incdec: IncDec|lint_incdec(st, incdec, used)",
        "dotassign|assign: DotAssign|lint_two(st, assign.obj, assign.v)",
        "kw_for|loop: For|lint_for(st, loop)",
        "store|store: Store|lint_two(st, store.p, store.v)",
    ], "lint_special_node(st, node, used)")
}#
