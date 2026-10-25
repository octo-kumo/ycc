type JustTag = { k: long };
type WithChild = { k: long, child: long };
type Shape = JustTag | WithChild;
def value(v: Shape) -> long {
    match v { JustTag _v => 1, WithChild v => v.child }
};
let leaf: JustTag = { k: 0 };
let child: WithChild = { child: 7, k: 0 };
print(value(leaf), value(child));
def tag(v: Shape) -> long { v.k };
print(tag(leaf), tag(child), tag(leaf));
let source = {a: [1], b: 2};
let copied = {...source, b: 9};
copied.a += 4;
print(source.b, copied.b, source.a[1]);
print(source == copied, source == source);
print([{x: 1}] == [{x: 1}], [source] == [source]);
print("a\x00x" == "a\x00y");
