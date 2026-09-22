// Test foreach loop
let arr = [10, 20, 30, 40, 50];
let total = 0;
foreach (x in arr) {
    total = total + x;
};
print("foreach sum = " + total);

// Test foreach with strings
let names = ["alice", "bob", "charlie"];
let greeting = "";
foreach (name in names) {
    greeting = greeting + name + " ";
};
print("foreach names = " + greeting);

// Test foreach over range()
let count = 0;
foreach (i in range(5)) {
    count = count + i;
};
print("foreach range sum = " + count);
