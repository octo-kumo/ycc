// expect-error: 4:18: error: '...' spread needs a record, got long
// expect-error: 5:17: error: record field 'field' has unsupported type void
// expect-error: 6:22: error: '...' spread is record-only (a map literal takes key: value entries)
let bad_spread = { ...1 };
let bad_field = { field: print(1) };
let bad_map_spread = { "key": 1, ...{ field: 2 } };
