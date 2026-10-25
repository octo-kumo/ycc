// expect-error: cannot modify 'A': it is a constant
// expect-error: cannot modify 'R': it is a constant
// expect-error: cannot modify 'M': it is a constant
// expect-error: cannot assign to constant 'A' ('+=')
// expect-error: cannot modify 'A': it is a constant ('++')
// expect-error: cannot modify 'A': it is a constant ('+=')
// `const` fixes the value, not just the binding: a store that reaches the
// value THROUGH a const name is refused, at the store. Reading is fine
// (native/t59_const.y is the positive half), and so is every one of these on
// a `let`.
//
// The plain-name forms keep their own message ("cannot assign to constant
// 'A' ('+=')", which e46 and src/tools/ytest/su_pkg.y pin); a form that goes through an
// element, a field or a slice names the const it went through and says why.
const A: [long] = [1, 2];
const R = {x: 1};
const M = {"k": 1};
A[0] = 7;
R.x = 3;
M["k"] = 2;
A += 3;
A[1]++;
A[0] += 5;
A[0:1] = [9];
R.x++;
print(1);
