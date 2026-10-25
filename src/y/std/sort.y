// std/sort.y -- sorting arrays, with or without a comparison of your own.
//
//     import sort;
//     print(sort.sort([3, 1, 2]));                    // [1, 2, 3]
//     print(sort.sort_str(["pear", "fig", "apple"]));  // ["apple", "fig", "pear"]
//     print(sort.sort_by([5, -1, 9], def (a: long, b: long) -> bool { abs(a) < abs(b) }));
//
// Y has no generics, so each element type has its own pair: long, str and
// float, with and without a `less` of your own. Every one of them is a merge
// sort, so it is stable (equal elements keep their order) and O(n log n), and
// `sort` is `sort_by` with `<` -- there is one implementation per element type
// and no comparison of your own to write when the natural one will do.
//
// `less(a, b)` answers "does a come before b": true sorts a first. It must be
// a strict order (no `a == b` true), or the merge's choice between two equal
// runs stops meaning anything.
export { sort_by, sort, sort_desc, sort_str_by, sort_str, sort_str_desc,
         sort_f_by, sort_f };

// Merge two sorted runs. `xs` is written in place, so the caller's array is
// the one that gets sorted -- a sort that copied would double the memory and
// the write bandwidth for nothing.
def merge_long(xs: [long], lo: long, mid: long, hi: long, less: (long, long) -> bool) -> long {
    let buf: [long] = [];
    let i = lo;
    let j = mid;
    while (i < mid || j < hi) {
        // Take from the left run unless the right run's element strictly
        // precedes it: one comparison, and equal elements keep their order,
        // which is the stable merge's whole point.
        if (j >= hi || (i < mid && less(xs[j], xs[i]) == false)) {
            buf += xs[i];
            i = i + 1;
        } else {
            buf += xs[j];
            j = j + 1;
        };
    };
    let k = 0;
    while (k < len(buf)) {
        xs[lo + k] = buf[k];
        k = k + 1;
    };
    0
};

def sort_by(xs: [long], less: (long, long) -> bool) -> [long] {
    if (len(xs) < 2) { xs }
    else {
        let mid = len(xs) / 2;
        let a = self(xs[0:mid], less);
        let b = self(xs[mid:len(xs)], less);
        let out = a + b;
        merge_long(out, 0, mid, len(out), less);
        out
    }
};

// Ascending, and descending.
def sort(xs: [long]) -> [long] {
    sort_by(xs, def (a: long, b: long) -> bool { a < b })
};

def sort_desc(xs: [long]) -> [long] {
    sort_by(xs, def (a: long, b: long) -> bool { b < a })
};

def merge_str(xs: [str], lo: long, mid: long, hi: long, less: (str, str) -> bool) -> long {
    let buf: [str] = [];
    let i = lo;
    let j = mid;
    while (i < mid || j < hi) {
        if (j >= hi || (i < mid && less(xs[j], xs[i]) == false)) {
            buf += xs[i];
            i = i + 1;
        } else {
            buf += xs[j];
            j = j + 1;
        };
    };
    let k = 0;
    while (k < len(buf)) {
        xs[lo + k] = buf[k];
        k = k + 1;
    };
    0
};

def sort_str_by(xs: [str], less: (str, str) -> bool) -> [str] {
    if (len(xs) < 2) { xs }
    else {
        let mid = len(xs) / 2;
        let a = self(xs[0:mid], less);
        let b = self(xs[mid:len(xs)], less);
        let out = a + b;
        merge_str(out, 0, mid, len(out), less);
        out
    }
};

def sort_str(xs: [str]) -> [str] {
    sort_str_by(xs, def (a: str, b: str) -> bool { a < b })
};

def sort_str_desc(xs: [str]) -> [str] {
    sort_str_by(xs, def (a: str, b: str) -> bool { b < a })
};

// Floats: `less` is `<`, so a NaN compares false both ways and keeps its place
// among its equals -- stable, and no comparison of your own needed for the
// 99% case. sort_f_by(a, def (x, y) -> bool { x > y }) is the descending one,
// NaNs last.
def merge_f(xs: [float], lo: long, mid: long, hi: long, less: (float, float) -> bool) -> long {
    let buf: [float] = [];
    let i = lo;
    let j = mid;
    while (i < mid || j < hi) {
        if (j >= hi || (i < mid && less(xs[j], xs[i]) == false)) {
            buf += xs[i];
            i = i + 1;
        } else {
            buf += xs[j];
            j = j + 1;
        };
    };
    let k = 0;
    while (k < len(buf)) {
        xs[lo + k] = buf[k];
        k = k + 1;
    };
    0
};

def sort_f_by(xs: [float], less: (float, float) -> bool) -> [float] {
    if (len(xs) < 2) { xs }
    else {
        let mid = len(xs) / 2;
        let a = self(xs[0:mid], less);
        let b = self(xs[mid:len(xs)], less);
        let out = a + b;
        merge_f(out, 0, mid, len(out), less);
        out
    }
};

def sort_f(xs: [float]) -> [float] {
    sort_f_by(xs, def (a: float, b: float) -> bool { a < b })
};