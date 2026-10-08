// echo [words...] -- print the arguments separated by spaces.
import ulib;
let a = argv();
let out = "";
let i = 1;
while (i < len(a)) {
    if (i > 1) { out += " "; };
    out += a[i];
    i = i + 1;
};
puts(out + "\n");
