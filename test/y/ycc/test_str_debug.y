let src = "hi\\n";
print("src len = " + tostring(len(src)));
let i = 0;
let n = len(src);
while (i < n) {
    let ch = src[i:i + 1];
    print("i=" + tostring(i) + " ch=" + ch + " ord=" + tostring(ord(ch)));
    if (ch == "\\") {
        print("  backslash, next=" + src[i + 1:i + 2]);
        i = i + 2;
    } else {
        i = i + 1;
    };
};
print("done");
