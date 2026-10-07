// flags: -W 2
def main() -> long {
    let i = 0;
    i = i + 1; // expect-warning: 'i = i + 1' can be written 'i++'
    i = i + 2; // expect-warning: 'i = i + <expr>' can be written 'i += <expr>'
    i += 1; // expect-warning: 'i += 1' can be written 'i++'
    i = i - 1; // expect-warning: 'i = i - 1' can be written 'i--'
    i -= 1; // expect-warning: 'i -= 1' can be written 'i--'
    let s = "hello";
    let c = byte_at(s, i); // expect-warning: 'byte_at(s, i)' can be written 's[i]'
    let q = s[i:i + 1]; // expect-warning: a one-character slice can be written as an index (a byte)
    let o = ord(s[i:i + 1]); // expect-warning: 'ord' of a one-character slice can be written as an index (a byte)
    let flag = true;
    if (flag == true) { print(c); }; // expect-warning: 'flag == true' can be written 'flag'
    if (flag != false) { print(q); }; // expect-warning: 'flag != false' can be written 'flag'
    if (flag == false) { print(o); }; // expect-warning: 'flag == false' can be written '!flag'
    if (flag != true) { print(0); }; // expect-warning: 'flag != true' can be written '!flag'
    let buf = s;
    if ((buf == s) == true) { print(1); }; // expect-warning: a comparison against true or false is the value itself, or its negation
    0
};
exit(main());
