import lexer from "../../../src/y/lexer.y";
import parser from "../../../src/y/parser.y";
import native from "../../../src/y/native.y";

print("imports loaded");
let src = "let x = 5;";
let toks = lexer.tokenize(src);
print("tokens = " + tostring(len(toks)));
