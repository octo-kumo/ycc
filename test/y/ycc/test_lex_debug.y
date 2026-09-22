import lexer from "../../../src/y/lexer.y";
let src = "let x = 5;";
print("tokenizing...");
let toks = lexer.tokenize(src);
print("done, count = " + tostring(len(toks)));
