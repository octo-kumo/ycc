// expect-error: 3:3: error: cannot assign to constant 'S' ('+=')
const S = "a";
S += "b";
print(S);
