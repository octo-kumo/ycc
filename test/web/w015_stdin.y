// W4: stdin crosses the host boundary -- the runner hands the module the
// fixture's .stdin file and readline() reads it a line at a time, newline
// stripped, none at end of input.
let n = 0;
let go = true;
let total = 0;
while (go) {
    let line = readline();
    if (line == none) {
        go = false;
    } else {
        let s = unwrap(line);
        n = n + 1;
        total = total + len(s);
        print(tostring(n) + ": [" + s + "] len=" + tostring(len(s)), "\n");
    };
};
print("lines=" + tostring(n) + " bytes=" + tostring(total), "\n");
