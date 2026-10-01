let xs = [1, 2, 3];
let copy = xs[:];
copy[0] = 9;
print(xs);
print(copy);
print(xs[-5:99]);
print(xs[5:1]);

let fixed: [long; 3] = [4, 5, 6];
print(fixed[1:]);
