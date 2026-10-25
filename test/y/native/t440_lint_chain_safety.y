// flags: --warnings=all
// Duplicates and permutations are sets, not source-ordered ranges.
def duplicate(n: long) -> bool {
    n == 1 || n == 3 || n == 1 // expect-warning: these equalities test one value against a set; write one membership test
}
def ordered(n: long) -> bool {
    n == 1 || n == 2 || n == 3 // expect-warning: these equalities are a consecutive range; write a range comparison
}
def permuted(n: long) -> bool {
    n == 3 || n == 1 || n == 2 // expect-warning: these equalities test one value against a set; write one membership test
}
// Complete, literal-valued chains retain the suggestion.
def complete(n: long) -> bool {
    if (n == 1) { true } // expect-warning: this 'if' chain tests one value against a set; write one membership test
    else if (n == 2) { true }
    else { false }
}
// Same-line chains remain advisory, never fed to the ambiguous text fixer.
def compact(n: long) -> bool {
    if (n == 1) { false } else if (n == 2) { false } else { true } // expect-warning: this 'if' chain tests one value against a set; write one membership test
}
def mixed(n: long) -> bool {
    if (n == 1) { true } // expect-warning: this 'if' chain tests one value against a set; write one membership test
    else if (n == 2) { true } else { false }
}
// A final side effect must not be discarded.
def effect(n: long) -> void {
    if (n == 1) { true }
    else if (n == 2) { true }
    else { print("SIDE"); };
}
// Missing else and void arms do not denote the proposed bool expression.
def missing(n: long) -> void {
    if (n == 1) { true }
    else if (n == 2) { true };
}
def void_arm(n: long) -> void {
    if (n == 1) { true; }
    else if (n == 2) { true }
    else { false };
}
def void_else(n: long) -> void {
    if (n == 1) { true }
    else if (n == 2) { true }
    else { false; };
}
def fallback(n: long, other: bool) -> bool {
    if (n == 1) { true }
    else if (n == 2) { true }
    else { other }
}
effect(3);
missing(3);
void_arm(3);
void_else(3);
print(duplicate(2), ordered(2), permuted(2));
print(complete(1), complete(3), compact(1), compact(3), mixed(3), fallback(3, true));
