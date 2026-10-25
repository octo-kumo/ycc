#{
    import shapes from "./type_schema.y";
    import codegen from "./shape_codegen.y";
    codegen.meta_shape_codegen("Type", "type", "k:long", shapes.TYPE_SHAPES, ["Err"], ["Field typ name opt", "RetNote typ line col"])
}#
