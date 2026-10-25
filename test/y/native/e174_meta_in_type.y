// expect-error: 3:15: error: a meta block cannot be inside a def or type body: only the top level and other blocks
type R = { v: long };
type S = { k: #{ "1" }# };
print(1);
