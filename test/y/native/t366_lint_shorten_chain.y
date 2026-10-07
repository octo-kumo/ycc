// flags: -W 2
def two(s: str) -> bool {
    s == "==" || s == "!=" || s == "<=" || s == ">=" || s == "&&" || s == "||" // expect-warning: these equalities test one value against a set of strings; write one membership test
};
def digit(c: byte) -> bool {
    c == '0' || c == '1' || c == '2' || c == '3' || c == '4' || c == '5' || c == '6' || c == '7' || c == '8' || c == '9' // expect-warning: these equalities are a consecutive range; write a range comparison
};
def oneop(c: byte) -> bool {
    c == '+' || c == '-' || c == '*' || c == '/' // expect-warning: these equalities test one value against a set; write one membership test
};
def main() -> long {
    print(two("=="));
    print(digit('5'));
    print(oneop('+'));
    0
};
exit(main());
