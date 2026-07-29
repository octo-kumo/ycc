let src = "hi\\n";
print("src len = " + tostring(len(src)));
let i = 0;
let n = len(src);
while (i < n) {
    let ch = substr(src, i, 1);
    print("i=" + tostring(i) + " ch=" + ch + " ord=" + tostring(ord(ch)));
    if (ch == "\\") {
        print("  backslash, next=" + substr(src, i+1, 1));
        i = i + 2;
    } else {
        i = i + 1;
    };
};
print("done");
