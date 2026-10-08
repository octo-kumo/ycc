// expect-error: 12:8: error: cannot read field 'k' of {long => str}: a dot name is a string, so the map's keys must be too (use m["k"])
// expect-error: 15:1: error: cannot field-assign {long => str}: a dot name is a string, so the map's keys must be too (use m["k"] = v)
// expect-error: 22:1: error: cannot field-assign {str => long} ('length' is a property, not an entry)
// expect-error: 23:10: error: cannot field-assign {str => long} ('length' is a property, not an entry)
// expect-error: 24:9: error: cannot field-assign {str => long} ('length' is a property, not an entry)
// TODO.md item 10 made a dot on a map an entry read. Two shapes stay rejected,
// and one is reserved:
//
// The KEY type is the constraint, not the value: a dot name is a string, so
// only a map keyed by one can be read with one. `{long => str}` keeps brackets.
let e: { long => str } = {};
print(e.k);

let f: { long => str } = {};
f.k = "v";

// `.length` is the number of entries, as it is for an array or a string, so it
// is not an entry -- and not a place either (t321 reads an entry named
// "length" through brackets). The three spellings of the mistake are one
// diagnostic: a plain store, an op-assign and an increment.
let m: { str => long } = { "k": 1 };
m.length = 3;
m.length += 1;
m.length++;

// `.ptr` is not a property of a map at all -- it has no data block to point
// into -- so a read and a store both say so, in the read's own words.
// expect-error: 29:8: error: {str => long} has no property 'ptr' (it has '.length')
print(m.ptr);
m.ptr = 0; // expect-error: 30:1: error: cannot field-assign {str => long}: it has no property 'ptr' (it has '.length')

// and a dot store is an ordinary store: the value has to fit the map's
m.a = "no"; // expect-error: 33:1: error: map entry 'a': expected long, got str