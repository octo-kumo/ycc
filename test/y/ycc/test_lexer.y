import lexer from "./lexer.y";

let src = "def add(a: long, b: long) { a + b };\nprint(add(3, 4));\n// comment\nlet x = \"hi\\n\";";
let toks = lexer.tokenize(src);
let i = 0;
while (i < len(toks)) {
    let tk = toks[i];
    print(tk.t + " : " + tk.v);
    i = i + 1;
};
