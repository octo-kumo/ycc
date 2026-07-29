let src = "let x = \"hi\\n\";";
print("src = " + src);
print("len = " + tostring(len(src)));
let i = 8;
let n = len(src);
print("starting at i=" + tostring(i) + " char=" + substr(src, i, 1));
i = i + 1;
let buf = "";
let open = true;
while (open && i < n) {
    let ch = substr(src, i, 1);
    print("i=" + tostring(i) + " ch=" + ch);
    if (ch == "\\") {
        let esc = substr(src, i + 1, 1);
        print("  escape: " + esc);
        if (esc == "n") { buf = buf + "\n"; i = i + 2; }
        else { buf = buf + esc; i = i + 2; };
    } else if (ch == "\"") {
        print("  closing quote");
        i = i + 1;
        open = false;
    } else {
        buf = buf + ch;
        i = i + 1;
    };
};
print("buf = " + buf);
print("done");
