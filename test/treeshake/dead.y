// A program whose only live statement is `print(answer())`. Everything else is
// there to be shaken away: three unused imports, a dead table, dead helpers
// (one called only from a branch that is never taken), an unused type and
// union, unused locals, and code after a return.
import math;
import regex;
import fs;

const DEAD_TABLE: [long] = [1, 2, 3, 4, 5, 6, 7, 8];
type Dead = { a: long, b: str, c: [long] };
type DeadOther = { q: float };
type DeadUnion = Dead | DeadOther;

def unused_helper(x: long) -> long { x * 2 + DEAD_TABLE[0] };
def unused_deep(a: Dead) -> str { "unused " + tostring(a.a) + a.b };
def unused_union(u: DeadUnion) -> long {
    match (u) { Dead d => d.a, DeadOther o => 1 }
};
def answer() -> long {
    if (false) { return unused_helper(5); };
    let never_read = "a dead string constant";
    let also_unread = 42;
    return 7;
    print(never_read);
    9
};
print(answer());
