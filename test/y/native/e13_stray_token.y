// expect-error: unexpected 'zzz'
// A token that is neither a separator nor the closer used to be dropped
// silently, so `[1, 2 zzz]` compiled as `[1, 2]`.
let a = [1, 2 zzz];
print(len(a));
