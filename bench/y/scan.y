// bench/y/scan.y — a little tokenizer over a generated "source": the
// mixed workload (per-char scans, substr, comparisons, token lists) that
// the compiler itself runs on every file.
def tokenize(lines: long) -> long {
let src = "";
let i = 0;
while (i < lines) {
    src = src + "let x" + tostring(i) + " = " + tostring(i * 3) + " + 1;\n";
    i = i + 1;
    0
};

let toks: [str] = [];
let n = len(src);
let p = 0;
while (p < n) {
    let c = substr(src, p, 1);
    if (c == " " || c == "\n" || c == "\t") {
        p = p + 1;
        0
    } else if (c == ";" || c == "=" || c == "+") {
        toks += c;
        p = p + 1;
        0
    } else if (c >= "0" && c <= "9") {
        let s = p;
        let go = true;
        while (go) {
            if (p < n) {
                let d = substr(src, p, 1);
                if (d >= "0" && d <= "9") {
                    p = p + 1;
                    0
                } else {
                    go = false;
                    0
                };
                0
            } else {
                go = false;
                0
            };
            0
        };
        toks += substr(src, s, p - s);
        0
    } else {
        let s = p;
        let go = true;
        while (go) {
            if (p < n) {
                let d = substr(src, p, 1);
                if (d >= "a" && d <= "z") {
                    p = p + 1;
                    0
                } else if (d >= "0" && d <= "9") {
                    p = p + 1;
                    0
                } else {
                    go = false;
                    0
                };
                0
            } else {
                go = false;
                0
            };
            0
        };
        toks += substr(src, s, p - s);
        0
    };
    0
};
len(toks)
};

print(tokenize(1500));
