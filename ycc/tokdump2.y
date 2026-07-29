import lexer from "./lexer.y";
let toks = lexer.tokenize("a[:][2]");
let i = 0;
while (i < len(toks)) {
    print(tostring(i) + ": " + toks[i].t + " '" + toks[i].v + "'");
    i = i + 1;
};
