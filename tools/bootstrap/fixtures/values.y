// Bootstrap-specific checks for implicit concatenation and nested appends.
def greet(who: str, punctuation: str = "!") -> str { "hello " + who + punctuation };
print(greet("Y"));
print("label_" + 42 + "_" + 7);
let rows: [[long]] = [];
let one: [long] = [];
rows += one;
rows[0] += 9;
let two: [long] = [3, 4];
rows += two;
rows += [[5]];
print(rows.length, rows[0][0], rows[1][1], rows[2][0]);
let data: [byte; 8] = [0; 8];
let result = syscall(22, &data[0]);
print(result == 0);
if (result == 0) {
    let r = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
    let w = data[4] | (data[5] << 8) | (data[6] << 16) | (data[7] << 24);
    syscall(3, r);
    syscall(3, w);
};
let words: [[byte]] = [bytes("one"), bytes("two")];
foreach (word in words) { syscall(1, 1, &word[0], len(word)); print("|"); };
