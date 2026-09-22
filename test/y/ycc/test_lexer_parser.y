import lexer from "./lexer.y";
import parser from "./parser.y";
print("imports loaded");
let toks = lexer.tokenize("let x = 5;");
print("tokens = " + tostring(len(toks)));
let ast = parser.parse_program(toks);
print("parsed kind = " + ast.k);
