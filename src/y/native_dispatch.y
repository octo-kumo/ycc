#{
    import taggen from "./dispatch_codegen.y";
    import schema from "./dispatch_schema.y";
    taggen.meta_tag_dispatch("gen_go(st: EmitSt, node: Node) -> EmitSt",
        schema.NATIVE_DISPATCH, schema.NATIVE_DISPATCH_OTHERWISE)
}#
