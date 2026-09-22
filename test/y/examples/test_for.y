// Test C-style for loop
let sum = 0;
for (let i = 0; i < 10; i = i + 1) {
    sum = sum + i;
};
print("for sum 0..9 = " + sum);

// Test for with step > 1
let evens = 0;
for (let j = 0; j < 20; j = j + 2) {
    evens = evens + 1;
};
print("for evens count = " + evens);

// Test for with no init
let k = 5;
let result = 1;
for (; k > 0; k = k - 1) {
    result = result * k;
};
print("for factorial 5 = " + result);
