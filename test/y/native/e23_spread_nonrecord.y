// expect-error: spread needs a record
// `...` spreads a record's fields into a record literal; anything else
// is a type error (there is nothing to spread).
let n = 5;
print({ ...n });
