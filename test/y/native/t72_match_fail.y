// The match fall-through is unreachable for a value of the subject's
// type; this one is not (read() overwrites the variable with zeros from
// stdin), so no member matches and the match traps.
type R = { x: long };
type S = { y: long };
let record: R | S = { x: 1 };
syscall(0, 0, &record, 8);
match record {
    R => 1,
    S => 2
};
