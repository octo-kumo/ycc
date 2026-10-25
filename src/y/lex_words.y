// Reserved/contextual classifiers generated from shared language metadata.
#{
    import vocabulary from "./language_schema.y";
    let out = "";
    foreach (spec in [{name: "lex_reserved", words: vocabulary.RESERVED_WORDS}, {name: "lex_contextual", words: vocabulary.CONTEXTUAL_WORDS}]) {
        let tests = "";
        foreach (word in spec.words) {
            if (tests != "") { tests += " || "; };
            tests += "word == \"" + word + "\"";
        };
        out += "def " + spec.name + "(word: str) -> bool { " + tests + " };\n";
    };
    out
}#
export { lex_reserved, lex_contextual };
