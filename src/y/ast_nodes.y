// Exact Node records and child operations, generated from one schema.
// Callers own recursion and scope-sensitive handling of functions/loops.
#{
    import shapes from "./ast_schema.y";
    import codegen from "./shape_codegen.y";
    codegen.meta_shape_codegen("Node", "node", "k:long line:long col:long", shapes.AST_SHAPES, [], [])
}#
