// expect-error: 2:4: error: 'ycc_meta_stmt' is reserved: the meta pass injects it into the generator
def ycc_meta_stmt(a: long) -> long { a };
let x = #{ "1" }#;
print(x);
