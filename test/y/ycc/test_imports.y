import lexer from "./lexer.y";
import parser from "./parser.y";
import codegen from "./codegen.y";

print("imports loaded");
let src = "let x = 5;";
let toks = lexer.tokenize(src);
print("tokens = " + tostring(len(toks)));
