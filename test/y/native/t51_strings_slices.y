// string indexing and slicing, character literals, slice assignment
let text = "hello world";
print(text[2:5]);
print(text[1]);
print(text[:5], "|", text[6:], "|", text[:]);
print(text[8:100], "|", text[5:2], "|");
print(text[0] == 'h');

let c = 'a';
print(c);
print(c + 1);
let nl = '\n';
print(nl);

// count vowels byte by byte
let vowels = 0;
for (let i = 0; i < len(text); i++) {
    let ch = text[i];
    if (ch == 'e' || ch == 'o') { vowels++; };
}
print(vowels);

let buf: [byte] = [1, 2, 3, 4, 5];
let buf2: [byte] = [6, 7, 8];
buf[0:3] = buf2;
print(buf);
buf[2:4] = buf2[0:2];
print(buf);

let xs = [1, 2, 3, 4, 5];
xs[1:3] = [20, 30];
print(xs);
xs[3:] = [40, 50];
print(xs);
xs[:] = [0, 0, 0, 0, 0];
print(xs);
let names = ["a", "b", "c"];
names[0:2] = ["x", "y"];
print(names);
