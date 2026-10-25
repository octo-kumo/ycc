// Generate both assembly entry points from the architecture recipes.
#{
    import recipes from "./x64_schema.y";
    import forms from "./ir_schema.y";
    import codegen from "./backend_codegen.y";
    codegen.meta_backend_codegen(recipes.X64_ENCODINGS, forms.IR_FORMS)
}#
