import lexer from "../../../src/y/lexer.y";
print("import loaded");
let toks = lexer.tokenize("let x = 5;");
print("tokens = " + tostring(len(toks)));
