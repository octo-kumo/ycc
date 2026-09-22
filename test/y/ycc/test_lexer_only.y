import lexer from "./lexer.y";
print("lexer imported");
let toks = lexer.tokenize("let x = 5;");
print("tokens = " + tostring(len(toks)));
