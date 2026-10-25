// expect-error: arrays support only
// Arrays mutate in place only through += (push/append) and *= (prepend);
// -= and friends are errors — there is no meaningful in-place meaning.
let a = [1, 2];
a -= 1;
print(len(a));
