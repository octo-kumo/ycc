// expect-error: 13:6: error: print supports long/bool/float/str/array/record/map/option, got void
// expect-error: 14:4: error: len supports arrays, strings and maps, got long
// expect-error: 15:5: error: cannot put void in an option
// expect-error: 16:8: error: is_some needs an option, got long
// expect-error: 17:5: error: trim string: expected str, got long
// expect-error: 18:4: error: ord string: expected str, got long
// expect-error: 19:8: error: byte_at string: expected str, got long
// expect-error: 20:8: error: byte_at index: expected long, got bool
// expect-error: 21:4: error: chr code: expected long, got bool
// expect-error: 22:7: error: tolong needs a str to parse or a float to truncate, got long
// expect-error: 23:8: error: tofloat needs a str to parse or a long to widen, got float
// expect-error: 24:9: error: tostring supports long/bool/float/str/array/record/map/option, got void
print(exit(0));
len(1);
some(exit(0));
is_some(1);
trim(1);
ord(1);
byte_at(1, 0);
byte_at("x", true);
chr(true);
tolong(1);
tofloat(1.5);
tostring(exit(0));