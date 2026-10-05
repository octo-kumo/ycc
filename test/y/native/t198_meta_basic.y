// The three positions a block can be in, and a nested block. The generator's
// value is spliced in as TEXT, so a str value has to be quoted first.
//
// With a block in the file the top level is also the generator's program, so
// the two `print`s at the end draw lint's "runs twice" warning (t199 has that
// test on its own); the text the block generated does not.
def lit(s: str) -> str {
    let out = "\"";
    let i = 0;
    while (i < s.length) {
        let c = byte_at(s, i);
        if (c == 34) { out += "\\\""; }
        else if (c == 92) { out += "\\\\"; }
        else if (c == 10) { out += "\\n"; }
        else { out += s[i:i + 1]; };
        i = i + 1;
    };
    out + "\""
};
def three(n: long) -> str {
    let out = "";
    for i in 0..n { out += "print(" + tostring(i) + ");\n"; };
    out
};
def outer(k: long) -> str {
    return three(k + 1)
};
// statement position: the text lands as the program's statements
#{ three(2) }#
// expression position: the value is a str, so it lands as a string literal
let text = #{ lit("a\nb") }#;
// and a nested block is DATA: its text is a value the outer block uses
let more = #{ lit(outer(2)) }#;
print(text); // expect-warning: a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure
print(more); // expect-warning: a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure
