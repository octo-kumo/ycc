// expect-error: 4:3: error: bigints support only '+', '-', '*', '/' and '%' with '='
// expect-error: 5:17: error: bigint literal '1.5n' is a float; a bigint is a whole number
let x: bigint = 1n;
x &= 1n;
let y: bigint = 1.5n;
print(x);
