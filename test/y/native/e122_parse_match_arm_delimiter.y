// expect-error: 4:11: error: expected ',' or '}' after a match arm, got ''
let r: { k: str } = { k: "x" };
match r.missing {
    1 => 2
