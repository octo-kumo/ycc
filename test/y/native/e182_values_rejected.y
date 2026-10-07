// expect-error: 9:13: error: values takes exactly 1 argument
// expect-error: 11:13: error: values needs a map, got long
// expect-error: 13:11: error: keys needs a map, got str
// TODO.md item 10 added `values(m)` beside `keys(m)`: both give the map's two
// arrays as copies, in the same insertion order, so keys(m)[i] and
// values(m)[i] are the same entry (t321_map_dot.y). `values` is checked like
// `keys` -- one argument, and it must be a map.
let m: { str => long } = { "k": 1 };
print(values(m, m));

print(values(1));

print(keys("s"));