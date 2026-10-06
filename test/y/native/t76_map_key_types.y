let bytes: {byte => str} = {};
bytes['a'] = "letter";
print(bytes['a']!);

let flags: {bool => long} = {};
flags[true] = 1;
flags[false] = 0;
print(flags[true]!);
print(flags[false]!);

let fractions: {float => str} = {};
fractions[1.5] = "three halves";
print(fractions[1.5]!);
print(fractions[2.5] == none);
