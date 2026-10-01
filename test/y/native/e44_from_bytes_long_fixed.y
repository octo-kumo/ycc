// expect-error: from_bytes argument: expected [byte] or [byte; N], got [long; 2]
let a: [long; 2] = [1, 2];
print(from_bytes(a));
