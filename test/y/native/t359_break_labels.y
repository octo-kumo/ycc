// `break outer` / `continue inner` resolve to an enclosing loop. An unknown
// name is the outermost loop; a name that matches an enclosing loop variable
// selects that loop.
def main() -> long {
    let grid = [[0, 1], [1, 1]];
    let found = 0;
    for x in 0..2 {
        for y in 0..2 {
            if grid[x][y] == 0 { break outer; };
            found = found + 100;
        };
        found = found + 1;
    };
    print(found);

    let count = 0;
    for outer in 0..3 {
        for y in 0..3 {
            if y == 1 { break outer; };
            count = count + 1;
        };
        count = count + 100;
    };
    print(count);

    let continued = 0;
    for x in 0..3 {
        for inner in 0..3 {
            if inner == 1 { continue inner; };
            continued = continued + 1;
        };
        continued = continued + 100;
    };
    print(continued);
    0
};

exit(main());
