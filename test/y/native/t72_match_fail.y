type R = { x: long };
let record: R = { x: 1 };
syscall(0, 0, &record, 8);
match record {
    R => 1
};
