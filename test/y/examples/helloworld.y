let ANSI = "\x1b[";
let RS = ANSI + "0m";
let D = ANSI + "2m";
let B = ANSI + "1m";
let R = ANSI + "31m";
let G = ANSI + "32m";
let Y = ANSI + "33m";
let BL = ANSI + "34m";
let M = ANSI + "35m";
let C = ANSI + "36m";
def w(s: str, color: str) {
    color + s + RS
};
let side = w("\\\\\\\\", R + B);
let face = w("(", BL) + side + w(" \xCF\x89 ", G + B) + side + w(")", BL);
print(w("Hello", G) + w(" World", Y) + w("!", R) + "\t" + face);