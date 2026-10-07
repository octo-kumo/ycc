// std/sort.y: sorting arrays, with and without a comparison of your own.
// Every one of them is a merge sort, so it is stable and O(n log n), and
// `sort` is `sort_by` with `<`.
import sort;
import math;

// the natural order, both directions
print(sort.sort([3, 1, 2]), " ", sort.sort_desc([3, 1, 2]));
print(sort.sort_str(["pear", "fig", "apple"]), " ", sort.sort_str_desc(["pear", "fig", "apple"]));
print(sort.sort_f([1.5, -0.5, 2.25]), " ");

// empty, one, two, duplicates, already sorted, reverse sorted
print(sort.sort([]), " ", sort.sort([7]), " ", sort.sort([2, 1]));
print(sort.sort([2, 2, 1, 1]), " ", sort.sort([1, 2, 3, 4]), " ", sort.sort([4, 3, 2, 1]));
print(sort.sort_str(["b", "a", "b", "a"]), " ");

// a comparison of your own: by absolute value
print(sort.sort_by([5, -1, 9, -3], def (a: long, b: long) -> bool { math.abs(a) < math.abs(b) }));
print(sort.sort_str_by(["B", "a", "C", "b"],
        def (a: str, b: str) -> bool { a.lower() < b.lower() }));
// and floats, descending
print(sort.sort_f_by([1.0, 3.0, 2.0], def (a: float, b: float) -> bool { b < a }));
// a NaN compares false both ways, so it keeps its place among its equals and
// never sinks to either end -- what makes the sort stable is observable here
print(sort.sort_f([2.0, math.nan, 1.0]));
print(sort.sort_f([math.nan, 2.0, math.nan, 1.0]));

// stable: with equal keys the order they arrived in is the order they leave
// in. A sort that is not stable may as well put 11 before 12.
print(sort.sort_by([12, 11, 21, 22], def (a: long, b: long) -> bool { a / 10 < b / 10 }));

// the caller's array is not touched: sort returns a new one
let xs = [3, 1, 2];
let ys = sort.sort(xs);
print(xs, " ", ys, " ", ys.length);

// and it scales: 1000 elements, checked rather than printed
let n = 1000;
let big: [long] = [];
let i = 0;
while (i < n) { big += ((i * 7919) % 1009) - 504; i = i + 1; };
let sorted = sort.sort(big);
let ok: bool = (len(sorted) == n) && (big != sorted || n < 2);
let j = 0;
while (ok && j + 1 < n) {
    if (sorted[j] > sorted[j + 1]) { ok = false; };
    j = j + 1;
};
let sum = 0;
j = 0;
while (j < n) { sum = sum + sorted[j]; j = j + 1; };
let sum0 = 0;
j = 0;
while (j < n) { sum0 = sum0 + big[j]; j = j + 1; };
print(ok, " ", sum == sum0, " ", sorted[0], " ", sorted[n - 1]);

// strings too, at size, with a checksum that would move if the order did
let words = ["delta", "alpha", "charlie", "bravo", "echo", "foxtrot", "golf", "hotel"];
let ws = sort.sort_str(words);
print(ws, " ", ws[0], " ", ws[7]);