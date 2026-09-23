const arr = [1, 2, 3, 4, 5];
print("arr[2] = " + arr[2]);
// tostring() is explicit: `+` would treat the array as the winning operand
// and CONCATENATE it (prepending the string), not stringify it.
print("arr[:] = " + tostring(arr[:]));
print("arr[1:] = " + tostring(arr[1:]));
print("arr[:2] = " + tostring(arr[:2]));
print("arr[1:3] = " + tostring(arr[1:3]));
print("arr[3:1] = " + tostring(arr[3:1]));
