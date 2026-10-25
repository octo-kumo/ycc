import langspec from "./language_schema.y";
import bgen from "./builtin_codegen.y";

def meta_string_methods() -> str {
    let out = "def str_method_shape(m: str) -> StrMethod {\n";
    foreach (spec in langspec.STRING_METHODS) {
        let cond = spec.names.split(" ").map(n => "m == \"" + n + "\"");
        let params = spec.params.map(t => bgen.meta_builtin_type(t));
        out += "if (" + bgen.meta_text_list(cond, " || ") + ") { return sm_mk(\"" + spec.fn + "\", [" + bgen.meta_text_list(params, ", ") + "], " + tostring(spec.required) + ", " + bgen.meta_builtin_type(spec.result) + ", \"" + spec.default + "\", " + tostring(spec.last) + "); };\n";
    };
    out + "sm_mk(\"\", [], 0, t_unk(), \"\", false) };\n"
};
export { meta_string_methods };
