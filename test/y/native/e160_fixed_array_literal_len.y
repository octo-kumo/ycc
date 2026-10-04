// A `[T; N]` annotation over an array LITERAL: the literal's element count
// must be N. The emitter allocates the block the literal built but bounds-
// checks it against the annotated N, so a shorter literal left every index
// from its length up reading and writing past the block with no trap -- and
// valgrind could not see it either, because the write landed in the block's
// own slack (06-arrays.tex: "allocated with exactly N slots", "bounds-
// trapped"). A `[T; N]` on the right-hand side carries its own count and was
// always checked, and a `[T]` annotation is untouched: that path only narrows
// the element type (`let b: [byte] = [104, 105]` still packs).
// expect-error: 11:1: error: let 'short': expected [long; 5], got [long]
let short: [long; 5] = [1, 2];
// expect-error: 13:1: error: let 'longer': expected [long; 2], got [long]
let longer: [long; 2] = [1, 2, 3];
// expect-error: 15:1: error: let 'packed': expected [byte; 16], got [long]
let packed: [byte; 16] = [104, 105];
// expect-error: 17:1: error: let 'texts': expected [str; 3], got [str]
let texts: [str; 3] = ["a", "b"];
// expect-error: 19:1: error: let 'floats': expected [float; 4], got [float]
let floats: [float; 4] = [1.5];