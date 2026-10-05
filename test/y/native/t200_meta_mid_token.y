// A block that has no operand position at its own byte offset -- its call
// cannot go there -- so its bytes are dropped from the generator program and
// the call is hoisted to the top-level statement that contains it. Removal is
// safe precisely BECAUSE it is mid-token: the block is an adjunct between two
// adjacent tokens, and dropping it leaves them adjacent.
//
// The near-misses below are NOT mid-token (the preceding byte starts an
// operand), so their calls stay in place and are expressions again -- which is
// why `str_len` takes a `str` and each piece is spelled as a literal: a
// block's value is spliced in as TEXT.
def nothing() -> str { "" };
def lit(s: str) -> str { "\"" + s + "\"" };
// mid-token in a def's NAME: a function name with a generated fragment. A
// block at the START of a name is not mid-token (no token ends there) and would
// leave `def () -> long` behind if its bytes were dropped, so it is refused --
// a name fragment needs a character of the name on one side.
//
// The generator program holds the def under the SHORT name (`as`), so nothing
// in the SOURCE may call it: the call is generated too. That is the shape --
// generate the name and its call sites together -- and it is what makes this
// usable at all.
const NAME = "sembled";
def as#{NAME}#() -> long { 7 };
// mid-token in the middle of an identifier
let tag#{nothing()}# = 5;
// mid-token between an object and a field: the two tokens just join
let bx: { x: long, y: long } = { x: 1, y: 2 };
let v = bx#{nothing()}#.y;
// mid-token where the block is the whole tail of the statement
let tail#{nothing()}#end = 9;
// and the near-misses, in place: an argument list, and a block's own value
def str_len(s: str, n: long) -> long { s.length + n };
let a = str_len(#{ lit("hi") }#, 10);
let r = { let q = #{ lit("99") }#; q.length };
let b = [10, 20, 30];
// the generated call has to come after the lets it uses, and after the def
// whose name the mid-token block generated
#{ "print(assembled(), tag, v, tailend, a, b[1], r);\n" }#
