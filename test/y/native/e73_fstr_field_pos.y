// expect-error: 5:5: error: undefined variable 'nope'
// a field spanning lines: its tokens keep their own positions
print(f"a {
    1 +
    nope
} b");
