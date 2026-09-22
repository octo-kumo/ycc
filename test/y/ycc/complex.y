def get(toks: [{ t: str, v: str }], p: long) -> str { toks[p].t };
def make(a: str, b: long) -> { x: str, y: long } { { x: a, y: b } };
export { get, make };
