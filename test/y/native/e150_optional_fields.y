// An optional field (`name?: T`) may be left out of a literal; a required
// one may not, nor may a field the type lacks. A literal two members of a
// union fit equally (each leaving out an optional field) is neither. And
// only a literal's optional field takes a plain T: a T is no T? elsewhere.
// expect-error: 12:1: error: let 'a': expected { url: str, timeout?: long }, got { timeout: long }
// expect-error: 13:15: error: record field 'timeout': expected long?, got str
// expect-error: 14:1: error: let 'c': expected { url: str, timeout?: long }, got { url: str, zzz: long }
// expect-error: 16:1: error: let 'u': expected { a: long, b?: long } | { a: long, c?: long }, got { a: long }
// expect-error: 17:1: error: let 'n': expected long?, got long
// expect-error: 18:25: error: expected ':' in a type, got ','
type Opts = { url: str, timeout?: long };
let a: Opts = { timeout: 5 };
let b: Opts = { url: "x", timeout: "slow" };
let c: Opts = { url: "x", zzz: 1 };
type U = { a: long, b?: long } | { a: long, c?: long };
let u: U = { a: 1 };
let n: long? = 5;
type Bad = { a: long, b?, c: long };
