def max3(a: long, b: long, c: long) -> long {
    if (a > b) { if (a > c) { a } else { c } } else if (b > c) { b } else { c }
};
print(max3(1, 2, 3));
print(max3(3, 2, 1));
def add(a: long, b: long) -> long { a + b };
def double(x: long) -> long { x * 2 };
print(double(add(3, 4)));
let n = 0;
while (n > 0) { n = n + 1; };
print(n);
if (false) { print(1); };
print(0 - 7);
print(-(3 + 4));
print(!false);
print(17 % 5);
let z = 0;
if (true) { let z = 5; print(z); };
print(z);
