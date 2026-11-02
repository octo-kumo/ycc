// Missing parameter types are inferred after parsing, from body literals and
// from literal call-site arguments. A call may precede the def.
def body(a) -> long { a + 1 };
def text(a) -> str { a + "!" };
def pair(a, b) -> long { a + b };

let n = 2;
print(body(n));
print(text("x"));
print(pair(3, 4));

print(forward(5));
def forward(a) -> long { a };
