print(0 && 5);
print(2 && 3);
print(0 || -1);
print(0 || 0);

let target = 1;
target = 7;
print(target);

let calls = 0;
def left() -> long { calls = calls + 1; print("L"); 1 };
def right() -> long { calls = calls + 1; print("R"); 2 };
let sum = left() + right();
print(sum);
print(calls);
