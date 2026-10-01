// join: the asm byte mover (y_str_join) -- empty array, empty sep and
// elements, word-boundary lengths, a 1000-element join, joins of joins,
// and the converted (long/bool) path.
def show(s: str) -> long {
    print("[" + s + "] " + tostring(len(s)));
    0
};

let e: [str] = [];
show(join(e, ","));
show(join(e, ""));
show(join(["a"], ","));
show(join(["", ""], ","));
show(join(["", "", ""], ""));
show(join(["abc", "", "defghijkl"], "--"));
show(join(["x", "y", "z"], ""));
show(join(["1234567", "12345678", "123456789"], "|"));

let big: [str] = [];
let i = 0;
while (i < 1000) {
    big += "item" + tostring(i);
    i = i + 1;
};
let j = join(big, ", ");
print(len(j));
print(substr(j, 0, 40));
print(substr(j, len(j) - 30, 30));

let words = split("the quick brown fox jumps over the lazy dog", " ");
show(join(words, "_"));
show(join([join(["a", "b"], "+"), join(["c", "d"], "-")], " = "));
show(join([1, 22, 333], ", "));
show(join([true, false], "/"));
let sep = "<" + "sep" + ">";
show(join(["p", "q", "r", "s"], sep));
