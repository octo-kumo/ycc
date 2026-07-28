// Test for..in range loop
let sum = 0;
for i in 0..10 {
    sum = sum + i;
};
print("for range sum 0..9 = " + sum);

// Test with non-zero start
let sum2 = 0;
for j in 5..15 {
    sum2 = sum2 + j;
};
print("for range sum 5..14 = " + sum2);

// Test nested ranges
let product = 0;
for a in 0..3 {
    for b in 0..3 {
        product = product + a * b;
    };
};
print("nested range product sum = " + product);

// Test range with expression bounds
let n = 4;
let fact = 1;
for k in 1..n+1 {
    fact = fact * k;
};
print("for range factorial 4 = " + fact);
