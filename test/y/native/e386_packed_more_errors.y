// expect-error: 8:12: error: field 'tag' is an array: set its elements through the pointer after creating the record
// expect-error: 9:17: error: sizeof takes a type, and offsetof a type and a field name: sizeof(Header), offsetof(Header, len)
// expect-error: 10:17: error: offsetof of a bitmap field is a bit offset: not supported
// An array field cannot be initialised in a literal, offsetof needs a field, and a bitmap
// field has a bit offset, not a byte one.
type R = packed { id: u16, tag: [byte; 4] };
type Bm = bits u8 { a, b };
let r: R = { tag: 3 };
let w = offsetof(R);
let b = offsetof(Bm, a);
