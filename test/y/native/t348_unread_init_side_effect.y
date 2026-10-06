// The purity rule, and it is the bug the first version of the pass had: an
// unread cell's initializer is NOT automatically dead. `let result = main(...)`
// is an unread global whose initializer holds the only CALL in the program,
// and deleting it produced a compiler that exited 0 and wrote nothing.
//
// So a range is droppable only when it makes no call except the allocator,
// writes no other cell and holds no raw text -- and this program prints both
// lines because the call in the unread initializer still runs.
def side_effect() -> long {
    print("the unread initializer ran");
    7
};
const UNREAD: long = side_effect();
const UNREAD_TABLE: [long; 3] = [side_effect(), side_effect(), side_effect()];
def main() -> long {
    print("main ran");
    0
};
exit(main());
