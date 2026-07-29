import lexer from "./lexer.y";
import parser from "./parser.y";

let src = "def add(a: long, b: long) { a + b }; print(add(3, 4 * 2));";
let toks = lexer.tokenize(src);
let ast = parser.parse_program(toks);
print("top = " + tostring(ast));
let s0 = ast.stmts[0];
print("s0 = " + tostring(s0));
