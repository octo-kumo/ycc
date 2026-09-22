import lexer from "../../../src/y/lexer.y";
let src = "let x = 5;";
let toks = lexer.tokenize(src);
print("tokens = " + tostring(len(toks)));
let i = 0;
while (i < len(toks)) {
    print(toks[i].t + ":" + toks[i].v);
    i = i + 1;
};
