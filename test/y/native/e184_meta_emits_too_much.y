// expect-error: error: the meta generator emitted more than 33554432 bytes
// A block whose text is unbounded in practice: the cap on emitted text is
// what keeps the piece table inside the memory budget (R8 is not negotiable).
def huge() -> str {
    let line = "// 0123456789012345678901234567890123456789012345678901234567890123\n";
    let out = "";
    for i in 0..600000 { out += line; };
    out
};
let x = #{ huge() }#;
print(1);
