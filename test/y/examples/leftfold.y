def left_fold(arr: [long], acc: long, f: (long, long) -> long) {
    if (arr == []) {
        acc
    } else {
        self(arr[1: ], f(acc, arr[0]), f)
    }
};
print("sum of 1+2+3+4=" + left_fold([1, 2, 3, 4], 0, def(acc: long, x: long) {
    acc + x
}));