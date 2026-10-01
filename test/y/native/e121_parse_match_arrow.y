// expect-error: 4:6: error: expected '=>' after a match pattern, got ''
let r: { k: str } = { k: "x" };
match r.missing {
    1
