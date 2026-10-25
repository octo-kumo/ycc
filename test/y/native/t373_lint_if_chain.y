// flags: --warnings=all
def isdigitch(c: byte) -> bool {
    if (c == '0') { true } // expect-warning: this 'if' chain tests one value against a set; write one membership test
    else if (c == '1') { true }
    else if (c == '2') { true }
    else { false }
};
def main() -> long { if (isdigitch('1')) { print(1); } else { print(0); }; 0 };
exit(main());
