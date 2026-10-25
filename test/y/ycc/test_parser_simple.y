import lexer from "../../../src/y/lexer.y";
import parser from "../../../src/y/parser.y";

let src = "let x = 5;";
let toks = lexer.tokenize(src);
print("tokens = " + tostring(len(toks)));
let ast = parser.parse_program(toks);
print("parsed, kind = " + ast.k);
