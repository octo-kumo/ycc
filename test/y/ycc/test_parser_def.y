import lexer from "../../../src/y/lexer.y";
import parser from "../../../src/y/parser.y";

let src = "def f() { 1 };";
print("tokenizing...");
let toks = lexer.tokenize(src);
print("tokens = " + tostring(len(toks)));
print("parsing...");
let ast = parser.parse_program(toks);
print("parsed, kind = " + ast.k);
print("stmts = " + tostring(len(ast.stmts)));
