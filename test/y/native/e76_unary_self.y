// expect-error: 4:15: error: 'self' outside of a function
// expect-error: 5:16: error: unary '-': expected long, got str
// expect-error: 6:16: error: unary '!': expected bool, got long
let outside = self;
let negative = -"x";
let inverted = !1;
