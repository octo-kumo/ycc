// Host operations keep their ABI when the compiler changes its output target.
// The runtime answers the architecture of this executable, including in meta.
ndef y_host_machine() -> long = "y_host_machine";

def is_arm() -> bool { y_host_machine() == 183 };
// The host OS is Linux on both supported machines; the arch is separate.
def name() -> str { "linux" };
def arch() -> str { if (is_arm()) { "aarch64" } else { "x64" } };

// The compiler's small set of Linux calls, named by their shared IR identities.
let host_numbers = [0, 1, 3, 8, 22, 33, 39, 57, 61, 72, 79, 257, 319, 322, 59];
let arm_numbers = [63, 64, 57, 62, 59, 24, 172, 220, 260, 25, 17, 56, 279, 281, 221];

def nr(n: long) -> long {
    if (!is_arm()) { return n; };
    for i in 0..len(host_numbers) { if (host_numbers[i] == n) { return arm_numbers[i]; }; };
    -1
};

def readlink(path: str, buf: *byte, size: long) -> long {
    if (is_arm()) { syscall(78, -100, path, buf, size) }
    else { syscall(89, path, buf, size) }
};

def mkdir(path: str, mode: long) -> long {
    if (is_arm()) { syscall(34, -100, path, mode) }
    else { syscall(83, path, mode) }
};
export { is_arm, name, arch, nr, readlink, mkdir };
