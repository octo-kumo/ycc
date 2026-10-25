#{
    import taggen from "./dispatch_codegen.y";
    taggen.meta_tag_dispatch("typeof_expr_go(st: TcSt, node: Node) -> TcRes", [
        "call|call: Call|typeof_call(st, call)",
        "block|block: Block|typeof_block(st, block)",
        "decl|decl: Decl|typeof_decl(st, decl)",
        "rectest|test: Narrow|typeof_rectest(st, test)",
        "narrow|narrow: Narrow|typeof_narrow(st, narrow)",
        "matchend|matchend: MatchEnd|typeof_matchend(st, matchend)",
        "sliceassign|assign: SliceAssign|typeof_sliceassign(st, assign)",
    ], "typeof_special_node(st, node)")
}#
