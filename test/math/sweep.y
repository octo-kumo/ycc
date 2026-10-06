import math;

let names: [str] = ["fabs", "fsign", "floor", "ceil", "trunc", "round", "fract", "cbrt", "exp", "exp2", "expm1", "log", "log2", "log10", "log1p", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "sqrt"];
let args: [float] = [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 0.25, 0.75, 1e-300, -1e-300, 1e-16, 1e+16, -1e+16, 5e-324, -5e-324, 2.2250738585072014e-308, -2.2250738585072014e-308, 1e-30, 1e+30, 0.6931471805599453, -0.6931471805599453, 0.34657359027997264, -0.34657359027997264, 0.7853981633974483, -0.7853981633974483, 1.5707963267948966, -1.5707963267948966, 3.141592653589793, -3.141592653589793, 709.0, 709.4, 709.782712893384, 710.0, 710.4, 710.47, -700.0, -745.0, -745.1332191019411, -746.0, -1000.0, 1e+308, -1e+308, 1e+300, 0.9999999925494194, -0.9999999925494194, 1.0 / 0.0, 0.0 - 1.0 / 0.0, 0.0 / 0.0];

def apply(k: long, x: float) -> float {
    if (k == 0) { math.fabs(x) }
    else if (k == 1) { math.fsign(x) }
    else if (k == 2) { math.floor(x) }
    else if (k == 3) { math.ceil(x) }
    else if (k == 4) { math.trunc(x) }
    else if (k == 5) { math.round(x) }
    else if (k == 6) { math.fract(x) }
    else if (k == 7) { math.cbrt(x) }
    else if (k == 8) { math.exp(x) }
    else if (k == 9) { math.exp2(x) }
    else if (k == 10) { math.expm1(x) }
    else if (k == 11) { math.log(x) }
    else if (k == 12) { math.log2(x) }
    else if (k == 13) { math.log10(x) }
    else if (k == 14) { math.log1p(x) }
    else if (k == 15) { math.sin(x) }
    else if (k == 16) { math.cos(x) }
    else if (k == 17) { math.tan(x) }
    else if (k == 18) { math.asin(x) }
    else if (k == 19) { math.acos(x) }
    else if (k == 20) { math.atan(x) }
    else if (k == 21) { math.sinh(x) }
    else if (k == 22) { math.cosh(x) }
    else if (k == 23) { math.tanh(x) }
    else { math.sqrt(x) }
};

let k = 0;
while (k < len(names)) {
    let i = 0;
    while (i < len(args)) {
        print(names[k], " ", i, " ", math.fbits(apply(k, args[i])));
        i = i + 1
    };
    k = k + 1
};