// Keep the TextMate vocabulary in step with compiler metadata, preserving layout.
import fs;
import json;
import languageparser from "../../../y/parser.y";
import language from "../../../y/language_schema.y";

def grammar_pattern(text: str, scope: str, words: [str]) -> str {
    let tag = "\"name\": \"" + scope + "\"";
    let at = index_of(text, tag);
    if (at < 0) { eputs("grammar: missing scope " + scope); exit(1); };
    let rest = text[at:];
    let begin = at + index_of(rest, "\"match\": ") + len("\"match\": ");
    let end = begin + index_of(text[begin:], "\n");
    let pattern = "\\b(" + "|".join(words) + ")\\b";
    text[:begin] + json.stringify_val(json.str(pattern), 0) + text[end:]
}

def grammar_main(av: [str]) -> long {
    if (len(av) < 2) { eputs("usage: grammar FILE [--check]"); return 1; };
    let source = fs.read_file(av[1]);
    if (!is_some(source)) { eputs("grammar: cannot read " + av[1]); return 1; };
    let text = source!;
    // Scopes express editor presentation; vocabulary belongs to the compiler.
    let special = "let const type import export embed from region heap true false none self def ndef".split(" ");
    let flow = (language.RESERVED_WORDS + language.CONTEXTUAL_WORDS).filter(w => !(w in special));
    let public = language.INTRINSICS.filter(w => !w.contains("$") && !w.contains("#") && w != "self" && w != "none");
    text = grammar_pattern(text, "keyword.control.flow.y", flow);
    text = grammar_pattern(text, "support.function.builtin.y", public);
    text = grammar_pattern(text, "support.type.y", languageparser.type_word_names());
    if (len(av) > 2 && av[2] == "--check") {
        if (text != source!) { eputs("grammar vocabulary is stale: run make lsp-grammar"); return 1; };
        return 0;
    };
    if (!fs.write_file(av[1], text)) { eputs("grammar: cannot write " + av[1]); return 1; };
    0
}
exit(grammar_main(argv()));
