// A const array cannot be mutated through any method.
// expect-error: 7:11: error: cannot modify 'a': it is a constant
// expect-error: 8:10: error: cannot modify 'a': it is a constant
// expect-error: 9:11: error: cannot modify 'a': it is a constant
def main() -> long {
    const a = [1, 2, 3];
    a.push(4);
    a.pop();
    a.sort((x, y) => x - y);
    0
}
exit(main());
