// A range counter can skip ahead, including through continue. Captures keep
// the native compiler's separate per-iteration cells.
for i in 0..6 { print(i); if (i == 0) { i += 2; continue; }; i++; };
let functions: [()->long] = [];
for i in 0..4 { functions += () => i; i++; };
print(len(functions), functions[0](), functions[1]());
