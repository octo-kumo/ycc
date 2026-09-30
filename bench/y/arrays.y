// bench/y/arrays.y — array growth, indexing, and an insertion sort: array
// header traffic plus element loops.
def sort_demo(n: long) -> long {
let a: [long] = [];
let i = 0;
while (i < n) {
    a += (i * 7919) % 10007;
    i = i + 1;
    0
};
let n = len(a);
let j = 1;
while (j < n) {
    let key = a[j];
    let k = j - 1;
    let go = true;
    while (go) {
        if (k >= 0) {
            if (a[k] > key) {
                a[k + 1] = a[k];
                k = k - 1;
                0
            } else {
                go = false;
                0
            };
            0
        } else {
            go = false;
            0
        };
        0
    };
    a[k + 1] = key;
    j = j + 1;
    0
};
a[0] + a[n - 1] + len(a)
};

print(sort_demo(14000));
