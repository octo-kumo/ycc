def left_fold(arr: [long], acc: float, f: (float, long) -> float) -> float {
    if (arr == []) {
        acc
    } else {
        self(arr[1: ], f(acc, arr[0]), f)
    }
};
const n = 1000;
let indices = range(n);
const pi = 4*left_fold(indices, 0.0, def(s:float, i:long) {
    let sign = if ((i%2) == 0) {1.0} else {-1.0};
    let denom = (2.0 * i) + 1;
    let v = s + sign / denom;
    v;
});
print("pi = "+pi);