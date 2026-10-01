// expect-error: 8:3: error: '*' left operand: expected long, got [long]
// expect-error: 9:5: error: '+' concatenated elements: expected long, got str
// expect-error: 10:3: error: '+' element: expected long, got str
// expect-error: 11:5: error: '+' element: expected long, got str
// expect-error: 12:5: error: '::' element: expected long, got str
// expect-error: 13:3: error: '::' needs an array on the right, got long
let a = [1];
a * a;
[1] + ["x"];
a + "x";
"x" + a;
"x" :: a;
1 :: 2;
