// signed division and modulo, including the idiv overflow pair
print(7 / -2);
print(-7 / 2);
print(-7 / -2);
print(7 / 2);
print(7 % -2);
print(-7 % 2);
print(-7 % -2);
print(7 % 2);

// LONG_MIN: idiv raises #DE on LONG_MIN / -1, and LONG_MIN % -1 with it
let mn = -9223372036854775807 - 1;
print(mn);
print(mn / -1);
print(mn % -1);
print(mn / 2);
print(mn % 3);
print(mn / -2);

// through variables, so nothing is constant-folded away
let a = -100;
let b = 7;
print(a / b);
print(a % b);
print(b / a);
print(b % a);
