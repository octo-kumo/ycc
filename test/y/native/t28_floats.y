// floats: literals, arithmetic, comparison, stringification, negation
let a = 1.5;
let b = 0.25;
print(a + b);
print(a - b);
print(a * b);
print(a / b);
print(-a);
print(a > b);
print(a < b);
print(a == 1.5);
print(a != b);
print(a >= 1.5);
print(b <= 0.25);

// long widens to float
let c: float = 2.0;
print(c * 3.0);

// stringification
print("a = " + a);
print("pi = " + 3.14159265);
print(tostring(0.5));

// float-returning function
def half(x: float) -> float {
    x / 2.0
};
print(half(9.0));

// accumulation in a loop
let sum = 0.0;
let i = 0;
while (i < 4) {
    sum = sum + 0.5;
    i = i + 1;
};
print(sum);
