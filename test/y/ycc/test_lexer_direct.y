import lexer from "../../../src/y/lexer.y";
let src = "let x = \"hi\\n\";";
print("calling tokenize...");
let toks = lexer.tokenize(src);
print("done, count = " + tostring(len(toks)));
let i = 0;
while (i < len(toks)) {
    print(tostring(i) + ": " + toks[i].t + " = " + toks[i].v);
    i = i + 1;
};
