// flags: --ob=full --ob-seed=4
// setcc + movzbq are VM opcodes, so boolean helpers stay in bytecode.
def lt(a: long, b: long) -> long { let x = a < b; if (x) { 1 } else { 0 } };
def eq(a: long, b: long) -> long { let x = a == b; if (x) { 1 } else { 0 } };
def gt(a: long, b: long) -> long { let x = a > b; if (x) { 1 } else { 0 } };
def main() -> long {
    print(tostring(lt(1, 2)) + " " + tostring(eq(3, 3)) + " " + tostring(gt(4, 2)));
    0
};
let r = main();
