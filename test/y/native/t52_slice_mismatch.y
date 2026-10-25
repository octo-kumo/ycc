// a slice assignment whose lengths disagree stops the program
let xs = [1, 2, 3, 4];
print("before");
xs[0:2] = [9, 9, 9];
print("not reached");
