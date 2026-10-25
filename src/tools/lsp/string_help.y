// Generated string method names and display signatures.
type StringHelp = { name: str, signature: str };
#{
    import json;
    import language from "../../y/language_schema.y";
    import helpgen from "../../y/builtin_codegen.y";
    let out = "const STRING_HELP: [StringHelp] = [\n";
    foreach (spec in language.STRING_METHODS) {
        let params: [str] = [];
        for i in 0..len(spec.params) {
            let typ = spec.params[i];
            let param = typ;
            if (i >= spec.required) {
                param += " = " + (typ == "str" ? json.stringify_val(json.str(spec.default), 0) : spec.default);
            };
            params += param;
        };
        foreach (name in spec.names.split(" ")) {
            let signature = name + "(" + helpgen.meta_text_list(params, ", ") + ") -> " + spec.result;
            out += "{name: " + json.stringify_val(json.str(name), 0) + ", signature: " + json.stringify_val(json.str(signature), 0) + "},\n";
        };
    };
    out + "];\n"
}#
export { StringHelp, STRING_HELP };
