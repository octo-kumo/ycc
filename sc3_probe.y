def strip_comments(src: str) -> str {
    let out = "";
    let n = len(src);
    let i = 0;
    while (i < n) {
        let c = substr(src, i, 1);
        if (c == "/") {
            let nxt = substr(src, i + 1, 1);
            if (nxt == "/") {
                let done = false;
                while (!done) {
                    if (i >= n) { done = true; 0 } else {
                        let d = substr(src, i, 1);
                        i = i + 1;
                        if (d == "\n") { out += "\n"; done = true; 0; } else { 0; };
                        0
                    };
                    0
                };
                0
            } else if (nxt == "*") {
                i = i + 2;
                while (i < n) {
                    let d = substr(src, i, 1);
                    if (d == "*") {
                        if (substr(src, i + 1, 1) == "/") { i = i + 2; 0; } else { i = i + 1; 0; };
                        0
                    } else {
                        if (d == "\n") { out += "\n"; 0; } else { 0; };
                        i = i + 1;
                        0
                    };
                    0
                };
                0
            } else {
                out += c;
                i = i + 1;
                0
            };
            0
        } else {
            out += c;
            i = i + 1;
            0
        };
        0
    };
    out
};
let s = "print(1);\n// c with exec\nexec(\"x\");\n/* block\ncomment */\nprint(2);\n";
print(len(strip_comments(s)));
