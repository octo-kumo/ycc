// A value whose type nests: printing one walks the type, and the walk carries
// the path it has taken so far. cycc built that path with `yav(len)` -- whose
// arguments are variadic -- and no arguments at all, so every level read `len`
// words of uninitialized stack into the array: harmless to the walk itself
// (which only compares identities), but it doubled the array and, deep enough,
// read off the top of the stack. cycc died with a SIGSEGV on fifteen nested
// array literals where ycc compiled and ran them; thirty levels is comfortably
// past that.
print([[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]);
print({a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: 1}}}}}}}}}}}}}}}}}}}}}}}}}}}}}});
print([[[[[[[[[[[[[[[[[[[[[[[[[[[[[[{a: 1}]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]);
// and the type itself, walked by typeof
let t: [[[[[[[[[[[[[[[[[[[[[[[[[[[[[[byte]]]]]]]]]]]]]]]]]]]]]]]]]]]]]] = [];
print(typeof(t));
