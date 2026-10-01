// expect-error: 3:11: error: an f-string field is one expression, got ','
let a = 1;
print(f"{a, a}");
