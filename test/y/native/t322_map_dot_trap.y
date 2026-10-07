// TODO.md item 10: `m.k` reads the entry named "k" -- no `none` for a missing
// one. The program stops with the key in the message, because a dot is a claim
// that the entry is there and a typo must not read as an absent value. The
// bracket spellings are the probe (`m["k"]` is `V?`) and its answer
// (`m["k"]!` traps too, with the option's own message).
let m: { str => long } = { "k": 1 };
print("before ");
print(m.lenght);
print("not reached");