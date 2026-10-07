// expect-error: 24:8: error: pattern type long can never match str
// expect-error: 27:8: error: pattern type str can never match long?
// expect-error: 30:8: error: pattern type float can never match str?
// expect-error: 34:8: error: pattern type str can never match byte?
// expect-error: 37:8: error: match pattern type void is not a record or primitive type
// expect-error: 40:8: error: pattern type sem can never match mutex
// TODO.md item 13 let a pattern name a scalar: `if let long n = v` is "is the
// subject one of these", and the checker has to say so when it cannot be --
// which is the only way the new spelling stays honest rather than silently
// binding garbage.
//
// The message names the payload, not the option: `long?` is an option whose
// payload is a long, so the mismatch is with `long`. The four above are the
// same shape each way round, including `byte`, which has no literal yet (item
// 7) and so has to come from an annotation.
//
// The last two are NOT narrowable. `void` and `sem` are the language's own
// names, so the parser builds their kinds here too now -- which used to be
// "unknown type 'void'" -- and from there each reaches the message its shape
// already had: `void` is no pattern type at all, and a mutex's value is a
// record, so `sem` against one is the same "can never match" a record member
// the pattern does not name gets.
let plain = "text";
if let long n = plain { print(n); };

let num: long? = some(1);
if let str t = num { print(t); };

let word: str? = some("x");
if let float f = word { print(f); };

let raw: byte = 65;
let byt: byte? = some(raw);
if let str u = byt { print(u); };

let just_num: long = 3;
if let void v = just_num { print(1); };

let m = mutex();
if let sem s = m { print(1); };
