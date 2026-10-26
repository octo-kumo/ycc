// flags: --ob=full --ob-seed=17
#{
    let text = "";
    for i in 0..120 {
        text += "def arm_page_" + tostring(i) + "(x: long) -> long { let a = x;";
        for j in 0..16 { text += "a = (a * 3 + " + tostring(j) + ") ^ x;"; };
        text += " a & 255 };\n";
    };
    text += "def work() -> long { let sum = 0;";
    for i in 0..120 { text += "sum += arm_page_" + tostring(i) + "(" + tostring(i) + ");"; };
    text += "sum };\n";
    text += "let first = spawn(() => work()); let second = spawn(() => work());";
    text += "print(work() == join(first), \" \", work() == join(second));";
    text
}#
