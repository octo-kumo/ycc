// expect-error: 3:5: error: a meta block in a def or type header must be part of a name, with a character of the name beside it: a call cannot go in a header, and dropping the block's bytes would leave nothing behind
def f() -> long { 1 };
def #{ "g" }#() -> long { 2 };
print(f());
