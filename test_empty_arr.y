// Test 5: empty array index - VM should crash with SIGFPE (% 0)
let arr = [];
let x = arr[0];
print(x);
