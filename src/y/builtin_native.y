// Intrinsic result types and lowering dispatch, expanded in native.y's scope.
#{
    import schema from "./builtin_schema.y";
    import codegen from "./builtin_codegen.y";
    let rows = schema.BUILTIN_RESULTS[:];
    foreach (shape in schema.BUILTIN_SHAPES) {
        let parts = shape.split("|");
        rows += parts[0] + "|" + codegen.meta_builtin_type(parts[1]);
    };
    codegen.meta_named_dispatch("infer_builtin(st: EmitSt, node: Call, name: str) -> Type", rows, "infer_func_ret(infer(st, node.callee))")
}#

#{
    import schema from "./builtin_schema.y";
    import codegen from "./builtin_codegen.y";
    codegen.meta_named_dispatch("gen_named_call(st: EmitSt, node: Call, name: str) -> EmitSt", schema.BUILTIN_LOWERINGS, "gen_named_special(st, node, name)")
}#
