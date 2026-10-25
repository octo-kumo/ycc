// expect-error: 4:9: error: u32 is only a pointer's target, and has no option type
// `*long?` is a pointer to an option; a sized integer cannot be wrapped, so
// `*u32?` is refused rather than read as an option of a pointer.
let a: *u32? = none;
