// expect-error: cannot bind a void value to 'x'
// arms that disagree make the if void: not a value
let x = if (true) { 1 } else { "one" };