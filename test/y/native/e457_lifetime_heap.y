// flags: --gc=never
// expect-error: lifetime: cannot prove reclamation
let kept: [str] = [];
for i in 0..10 {
    region {
        let scratch = [i; 100];
        heap { kept += tostring(scratch[0]); }
    }
}
print(kept.length);
