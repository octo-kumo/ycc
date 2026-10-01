def key(r: {k: str}) -> str {
    r.k
};

let extended = {k: "value", extra: 1};
print(key(extended));
