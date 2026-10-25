// echo [-n] [words...] -- print the arguments separated by spaces.
import ulib;
let a = argv();
let out = "";
let nl = true;
let i = 1;
if (len(a) > 1 && a[1] == "-n") { nl = false; i = 2; };
let first = i;
while (i < len(a)) {
    if (i > first) { out += " "; };
    out += a[i];
    i = i + 1;
};
if (nl) { out += "\n"; };
ulib.write(1, out);
