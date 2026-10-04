// Printing a map nested inside another value used to print its heap address:
// gen_val_tostr_rax (the walk that formats a value already in hand) had arms
// for str, bool, float, arrays, options, records and unions, and fell through
// to y_long_tostr for anything else -- so a map inside an array, an option or
// a record came out as `[140062647910408]`, a number that changes every run
// and describes nothing. The map now formats the way tostring() gives it, with
// its keys quoted when they are strings (04-types.tex: maps as "{"k": v, ...}").
let d = { "k": 1, "j": 26 };
let empt: {str => long} = { };
let raw: [byte] = [1, 2, 255];
// a literal's keys are strings; a long-keyed map is built from an annotated
// empty one (04-types.tex, Maps)
let nums: {long => str} = { };
nums[1] = "one";
nums[2] = "two";

// every container that reaches the value walk
print("in array: ", [d, d]);
print("in fixed array: ", [d; 2]);
print("in option: ", some(d));
print("in array of options: ", [some(d), none]);
print("alone: ", d);
print("empty: ", empt, " ", [empt]);
print("long keys: ", [nums, nums]);
print("deep: ", { "outer": [d, d] });
print("map of maps: ", { "a": { "b": 1 } });
print("map of options: ", { "p": some(1), "q": none });
print("map of arrays: ", { "xs": [1, 2], "ys": [3] });
print("map of bytes: ", { "raw": raw });
print("map of long-keyed maps: ", { "outer": nums });

// the nested form and tostring() of the same value agree
let boxed = [d, d];
let longboxed = [nums, nums];
print(tostring(boxed[0]) == tostring(d));
print(tostring(longboxed[1]) == tostring(nums));
print(tostring([empt]) == "[{}]");
// and the entries are the map's own
print(d["k"], " ", d["j"], " ", nums[2]);
// two equal maps print the same, and compare equal
print(boxed[0] == d, " ", [d] == [d]);