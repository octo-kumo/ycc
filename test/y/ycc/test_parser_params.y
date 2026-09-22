import lexer from "./lexer.y";
import parser from "./parser.y";

let src = "def f(a: long) { a };";
print("tokenizing...");
let toks = lexer.tokenize(src);
print("tokens = " + tostring(len(toks)));
print("parsing...");
let ast = parser.parse_program(toks);
print("parsed, kind = " + ast.k);
print("stmts = " + tostring(len(ast.stmts)));
