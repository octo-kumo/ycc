// flags: --gc=never
// expect-error: lifetime: cannot prove reclamation
// expect-error: opt in with --gc=auto
let kept: [str] = [];
for i in 0..10 { kept += "item " + tostring(i); }
print(kept.length);
