// tostring() of arrays, matching the VM's format exactly
print(tostring([1, 2, 3]));
print(tostring(["a", "b"]));
print(tostring([true, false]));
print(tostring([1.5, 2.5]));
print(tostring([[1, 2], [3]]));
print(tostring([42]));

let e: [long] = [];
print(tostring(e));

// slices stringify like any other array (examples/array.y relies on this)
let arr = [1, 2, 3, 4, 5];
print("arr[:] = " + tostring(arr[:]));
print("arr[1:] = " + tostring(arr[1:]));
print("arr[:2] = " + tostring(arr[:2]));
print("arr[1:3] = " + tostring(arr[1:3]));
print("arr[3:1] = " + tostring(arr[3:1]));

// nested in a bigger string, and through a function boundary
def show(a: [long]) -> str { "<" + tostring(a) + ">" };
print(show(arr));
print("x=" + tostring([9, 8]) + "!");
