// expect-error: 7:1: error: type 'Loop' refers to itself outside any record field, array, option, map or function type
// expect-error: 11:16: error: match pattern type long is not a record type
// expect-error: 14:15: error: no record in { a: long } | { b: long } has the fields of pattern { z }
// expect-error: 15:11: error: cannot match a record pattern against long
type R = { x: long };
let record: R = { x: 1 };
type Loop = Loop;
let recursive: Loop = 0;
match recursive { Loop value => 1, _ => 0 };
type N = long;
match record { N n => 1, _ => 0 };
type U = { a: long } | { b: long };
let union: U = { a: 1 };
match union { ({ z: 1 }) z => 1, _ => 0 };
match 1 { ({ x: 1 }) x => 1, _ => 0 };
