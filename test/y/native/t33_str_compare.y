// lexicographic string comparison
print("a" < "b");
print("b" < "a");
print("a" < "a");
print("a" <= "a");
print("a" >= "a");
print("abc" < "abd");
print("abc" < "ab");
print("ab" < "abc");
print("" < "a");
print("" < "");
print("Z" < "a");
print("apple" > "Apple");
print("apple" >= "apple");

// through variables, and on values built at run time
let x = "kiwi";
let y = "lemon";
print(x < y);
print(y < x);
print(x + "!" > x);
print(substr("zebra", 0, 1) > "a");

// a comparison-driven sort (insertion sort over strings)
let names = ["pear", "apple", "fig", "date"];
let i = 1;
while (i < len(names)) {
    let j = i;
    while (j > 0) {
        let a = names[j - 1];
        let b = names[j];
        if (a > b) {
            names[j - 1] = b;
            names[j] = a;
            j = j - 1;
        } else {
            j = 0;
        };
    };
    i = i + 1;
};
print(join(names, ","));
