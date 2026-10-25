// expect-error: 6:1: error: record field 'field': expected long, got str
// expect-error: 8:1: error: cannot field-assign long (only records)
// expect-error: 9:1: error: cannot field-assign long (only records)
// expect-error: 10:7: error: cannot read field 'field' of long (need a record)
let record = { field: 1 };
record.field = "wrong";
let number = 1;
number.field = 2;
(number + 1).field = 2;
number.field;
