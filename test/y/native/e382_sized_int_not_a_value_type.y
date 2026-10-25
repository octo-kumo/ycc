// expect-error: 6:8: error: u32 is only a pointer's target (write *u32)
// expect-error: 7:9: error: i16be is only a pointer's target (write *i16be)
// expect-error: 8:1: error: parameter 'x' has no type (annotate it)
// expect-error: 8:10: error: u16 is only a pointer's target (write *u16)
// A sized integer is a pointer target only; a value is a long (or byte).
let a: u32 = 1;
let b: [i16be] = [];
def f(x: u16) -> long { 0 };
