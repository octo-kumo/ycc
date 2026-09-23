// readline(): a line at a time, newline stripped, null at end of input
let n = 0;
let go = true;
while (go) {
    let line = readline();
    if (line == null) {
        go = false;
    } else {
        let s = unwrap(line);
        n = n + 1;
        print(tostring(n) + ": [" + s + "] len=" + tostring(len(s)));
    };
};
print("lines=" + tostring(n));

// EOF is not latched, so asking again is legal (and null here: stdin is done)
let again = readline();
if (again == null) { print("eof again"); } else { print("unexpected"); };
