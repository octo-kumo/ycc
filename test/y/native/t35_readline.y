// readline(): a line at a time, newline stripped, none at end of input
let n = 0;
let go = true;
while (go) {
    let line = readline();
    if (line == none) {
        go = false;
    } else {
        let s = unwrap(line);
        n = n + 1;
        print(tostring(n) + ": [" + s + "] len=" + tostring(len(s)));
    };
};
print("lines=" + tostring(n));

// EOF is not latched, so asking again is legal (and none here: stdin is done)
let again = readline();
if (again == none) { print("eof again"); } else { print("unexpected"); };
