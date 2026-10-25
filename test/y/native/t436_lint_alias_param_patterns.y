// flags: --warnings=all
// Pattern subjects are generated temporaries, not source-level aliases.
def scale(n: long, factor?: long) -> long {
    if let some(k) = factor { n * k } else { n }
}
def payload(value: long?) -> long {
    match value { some(n) => n, none => 0 }
}
type Num = { n: long };
type Pair = { l: long, r: long };
type Value = Num | Pair;
def total(value: Value) -> long {
    match value { Num { n } => n, Pair { l, r } => l + r }
}
def left(value: Value) -> long {
    if let Pair { l, r } = value { l - r } else { 0 }
}
def named(value: Value) -> long {
    match value { Num item => item.n, Pair item => item.l + item.r }
}
// Actual written aliases still warn, including before a match.
def alias(value: long) -> long {
    let n = value; // expect-warning: 'n' is only another name for the parameter 'value'; rename the parameter
    n + n
}
def alias_match(value: long?) -> long {
    let option = value; // expect-warning: 'option' is only another name for the parameter 'value'; rename the parameter
    match option { some(n) => n + payload(option), none => 0 }
}
// Preserve the existing exclusions for casts, reads and writes.
def typed(value: long) -> long {
    let n: long = value;
    n + n
}
def both(value: long) -> long {
    let n = value;
    value + n + n
}
def written(value: long) -> long {
    let n = value;
    n++;
    n + n
}
print(scale(3), scale(3, 4));
print(payload(some(7)), payload(none));
print(total({ n: 5 }), total({ l: 9, r: 2 }));
print(left({ l: 9, r: 2 }), left({ n: 5 }));
print(named({ n: 5 }), named({ l: 9, r: 2 }));
print(alias(3), alias_match(some(8)));
print(typed(3), both(3), written(3));
