// A record union and an exhaustive match.
type Num = { tag: str, n: long };
type Text = { tag: str, s: str };
type Value = Num | Text;

def show(v: Value) -> str {
    match v {
        Num n => n.tag + ":" + tostring(n.n),
        Text t => t.tag + ":" + t.s
    }
};
print(show({ tag: "n", n: 7 }));
print(show({ tag: "s", s: "hi" }));
