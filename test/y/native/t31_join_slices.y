// join over every element type, and open-ended slices
print(join([1, 2, 3], ","));
print(join([true, false], "-"));
print(join([1.5, 2.5], " "));
print(join(["a", "b"], "+"));

let empty: [long] = [];
print("[" + join(empty, ",") + "]");
print(join([7], ","));

let a = [1, 2, 3, 4, 5];
print(join(a[:], ","));
print(join(a[1:], ","));
print(join(a[:2], ","));
print(join(a[1:3], ","));
print(join(a[3:1], ","));
print(len(a[3:1]));

// slices are copies: writing through one does not touch the other
let b = a[0:3];
b[0] = 99;
print(join(a, ","));
print(join(b, ","));

// negative-ish and clamped bounds behave like the VM
print(join(a[0:99], ","));
