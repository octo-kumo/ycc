// The first `syscall` argument is the call number: it lands in %rax and the
// kernel reads it as the number. Only a number belongs there. A `str` there is
// a heap pointer, so the kernel takes its address as the call number while
// every argument register still holds whatever the stack held -- a silent
// arbitrary syscall, which `09-builtins.tex` does not document as possible.
// Arguments 1..6 keep the wide set (long/bool/str/*T), and a `byte` number
// is fine: it is a number.
// expect-error: 9:16: error: syscall needs a number first, got str
let a = syscall("write");
// expect-error: 11:16: error: syscall needs a number first, got bool
let b = syscall(true);
// expect-error: 13:16: error: syscall needs a number first, got float
let c = syscall(1.5);
let rows: [long] = [1, 2];
// expect-error: 16:16: error: syscall needs a number first, got [long]
let d = syscall(rows);
let words: [str] = ["seccomp"];
// expect-error: 19:16: error: syscall needs a number first, got [str]
let e = syscall(words, 1);
let good_num = syscall(39);
let good_byte: byte = 60;
let good_exit = syscall(good_byte, 0);