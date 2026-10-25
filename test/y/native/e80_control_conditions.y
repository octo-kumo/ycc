// expect-error: 7:1: error: 'if' condition: expected bool, got long
// expect-error: 8:1: error: 'while' condition: expected bool, got long
// expect-error: 9:1: error: 'for' condition: expected bool, got long
// expect-error: 10:1: error: 'foreach' needs an array, a map or a string, got long
// expect-error: 11:1: error: 'for' range start: expected long, got bool
// expect-error: 12:1: error: 'for' range end: expected long, got str
if 1 { 0; };
while 1 { 0; };
for (; 1; ) { 0; };
foreach (item in 1) { 0; };
for i in true..2 { 0; };
for j in 0.."end" { 0; };
