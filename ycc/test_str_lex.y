import lexer from "./lexer.y";
let src = "let x = \"hi\\n\";";
print("tokenizing: " + src);
let toks = lexer.tokenize(src);
print("done, count = " + tostring(len(toks)));
