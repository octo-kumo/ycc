import lexer from "../../../src/y/lexer.y";
import parser from "../../../src/y/parser.y";

let src = "def add(a: long, b: long) { a + b }; print(add(3, 4 * 2));";
let toks = lexer.tokenize(src);
let ast = parser.parse_program(toks);
print("top = " + tostring(ast));
// NOTE: split chain — the C parser misparses `ast.stmts[0]` inline
// (reads it as dot(ast, index(stmts, 0))).
let stmts = ast.stmts;
let s0 = stmts[0];
print("s0 = " + tostring(s0));
