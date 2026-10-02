// `{ k: str }` is an ordinary record type: one field, k.
def key(r: { k: str }) -> str { r.k };
print(key({ k: "value" }));
let r: { k: str } = { k: "a" };
r.k = "b";
print(key(r), " ", r);
// as a member of a union, told apart from the others by match
type Prim = { k: str };
type Arr = { k: str, of: T };
type T = Prim | Arr;
def show(t: T) -> str {
    match t {
        Prim p => p.k,
        Arr a => a.k + "(" + self(a.of) + ")"
    }
}
let t: T = { k: "tarr", of: { k: "tarr", of: { k: "tlong" } } };
print(show(t), " ", t.k);
