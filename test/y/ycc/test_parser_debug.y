import lexer from "../../../src/y/lexer.y";
import parser from "../../../src/y/parser.y";

let src = "def add(a: long, b: long) { a + b }; print(add(3, 4 * 2));";
print("tokenizing...");
let toks = lexer.tokenize(src);
print("tokens = " + tostring(len(toks)));
let i = 0;
while (i < len(toks)) {
    print(tostring(i) + ": " + toks[i].t + " = " + toks[i].v);
    i = i + 1;
};
print("parsing...");
let ast = parser.parse_program(toks);
print("parsed, kind = " + ast.k);
