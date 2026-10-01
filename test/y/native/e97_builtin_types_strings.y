// expect-error: 12:9: error: index_of string: expected str, got long
// expect-error: 13:9: error: index_of sub: expected str, got bool
// expect-error: 14:14: error: last_index_of string: expected str, got bool
// expect-error: 15:14: error: last_index_of sub: expected str, got long
// expect-error: 16:5: error: join needs an array, got long
// expect-error: 17:5: error: join delimiter: expected str, got long
// expect-error: 18:6: error: split string: expected str, got long
// expect-error: 19:6: error: split delimiter: expected str, got bool
// expect-error: 20:6: error: range count: expected long, got bool
// expect-error: 21:6: error: bytes argument: expected str, got long
// expect-error: 22:11: error: from_bytes argument: expected [byte], got [long]
index_of(1, true);
index_of("x", true);
last_index_of(true, 1);
last_index_of("x", 1);
join(1, 2);
join([], 2);
split(1, false);
split("x", false);
range(false);
bytes(1);
from_bytes([1]);
