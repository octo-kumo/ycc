// expect-error: 3:9: error: format spec 'd': type 'd' needs an integer, not float
let x = 1.5;
print(f"{x:d}");
