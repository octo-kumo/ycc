// expect-error: 18:5: error: cannot index str (only arrays and maps)
// expect-error: 19:6: error: cannot index str (only arrays and maps)
// expect-error: 20:9: error: cannot field-assign [long] (only records)
// expect-error: 21:10: error: cannot field-assign [long] (only records)
// expect-error: 22:1: error: cannot field-assign [long] (only records)
// expect-error: 23:10: error: cannot field-assign str (only records)
// expect-error: 24:7: error: cannot assign to this expression ('++')
// expect-error: 25:9: error: cannot assign to this expression ('+=')
// expect-error: 26:4: error: cannot assign to this expression ('-=')
// `++`/`--` and `op=` store back into their target, so it must be a place
// `=` stores to: a str's bytes, the `.length` and `.ptr` of an array or a
// str, a slice, an unwrapped option and `*p` are none.
let s = "ab";
let a = [1, 2];
let m = {"k": 1};
let x = 1;
let p = &x;
s[0]++;
s[1] += 1;
a.length++;
a.length -= 1;
--a.ptr;
s.length *= 2;
a[0:1]++;
m["k"]! += 1;
*p -= 1;
