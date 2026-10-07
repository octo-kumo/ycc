// flags: -W 2
def f(m: {str => long}, k: str) -> long {
    let x = m[k]; // expect-warning: 'x' is tested for 'none' and unwrapped; write 'if let some(x) = <expr> { ... } else { ... }'
    if (x == none) { 0 } else { x! + 1 }
};
def main() -> long { print(f({ "a": 5 }, "a")); 0 };
exit(main());
