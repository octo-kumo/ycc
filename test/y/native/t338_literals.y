// The literal spellings: a character literal is 'a' (one byte, typed byte),
// a byte literal carries a `b` suffix (129b, 0b10001b, 0o17b), and a
// triple-quoted string spans lines and may hold a `"`.
print('a');
print('a' + 0);
print(65b);
print(255b);
print(0b10001b);
print(0o17b);
print(129b);

// a byte literal is a byte: it unifies with a byte, not with a str
let bv: byte = 200b;
print(bv);
let bs: [byte] = [1b, 2b, 3b];
print(len(bs), " ", tostring(bs[2]));

// """...""" -- newlines and a `"` inside are text, escapes still mean what
// they mean
let m = """line one
line "two"
line three""";
print(len(m));
print(m);

// f"""...""" -- the same, with fields
let n = 7;
let f = f"""n is {n}
and "quoted" """;
print(f);
print(len(f));

// a one-line f-string still works, and a `{` is still escaped by doubling
print(f"[{{{n}}}]");
