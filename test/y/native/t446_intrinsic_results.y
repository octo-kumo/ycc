// Intrinsic result types must preserve option payloads and overloaded calls.
let worker = spawn { some(41) };
let answer = join worker;
let gate = mutex();
let words = lock gate { ["left", "right"] };
print(join(words, "|"), " ", unwrap(answer) + 1);
print(tolong("27"), " ", tofloat("2.5"), " ", bytes("ok"));
let entries = {"first": some(3), "second": some(5)};
print(keys(entries), " ", values(entries));
print(from_bytes(bytes("roundtrip")), " ", is_some(answer));
