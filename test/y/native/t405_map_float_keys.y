// A float-keyed map has the hash index too (past 8 entries), with 0.0 and -0.0 one
// key and a NaN key never found again (every insert of one is a new entry).
let m: { float => long } = {};
for i in 0..2000 { m[tofloat(i)! * 0.5] = i; };
print(len(m));
print(m[0.0]); print(m[1.5]); print(m[999.5]); print(m[1000.0]);
print(m[0.25] == none);
m[1.5] = 7;
print(m[1.5]); print(len(m));
let z = 0.0 - 0.0;
print(m[z]);
m[z] = 11;
print(m[0.0]); print(len(m));
let nan = 0.0 / 0.0;
m[nan] = 5;
print(len(m));
print(m[nan] == none);
m[nan] = 6;
print(len(m));
let s = 0;
for i in 0..2000 { s += m[tofloat(i)! * 0.5]!; };
print(s);
let small: { float => str } = {};
small[1.5] = "a"; small[2.5] = "b";
print(small[1.5]); print(small[2.5]); print(small[3.5] == none);
