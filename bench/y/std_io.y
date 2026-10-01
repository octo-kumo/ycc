import io;

def make_chunk() -> str {
    let bytes: [byte] = [];
    let i = 0;
    while (i < 4096) {
        bytes += 65;
        i = i + 1;
    };
    let part = from_bytes(bytes);
    let out = "";
    i = 0;
    while (i < 16) {
        out = out + part;
        i = i + 1;
    };
    out
};

def run() -> long {
    let path = "std_io_bench_" + tostring(syscall(39)) + ".dat";
    let chunk = make_chunk();
    let size = len(chunk);
    let chunks = 32;
    let fd = io.open(path, io.O_WRONLY() + io.O_CREAT() + io.O_TRUNC(), 420);
    let i = 0;
    let written = 0;
    while (i < chunks) {
        written = written + io.write_str(fd, chunk, size);
        i = i + 1;
    };
    io.close(fd);

    let input = io.open(path, io.O_RDONLY(), 0);
    let buffer: [long; 8192] = [0; 8192];
    let total = 0;
    let checksum = 0;
    let reading = true;
    while (reading) {
        let n = io.read(input, &buffer[0], size);
        if (n <= 0) {
            reading = false;
            0
        } else {
            total = total + n;
            let word = 0;
            while (word < n / 8) {
                let value = buffer[word];
                if (value == 0x4141414141414141) {
                    checksum = checksum + 520;
                    0
                } else {
                    exit(1);
                    0
                };
                word = word + 1;
            };
            0
        };
        0
    };
    io.close(input);
    syscall(87, path);
    if (written != chunks * size || total != written) { exit(1); 0 } else { 0; };
    checksum
};

print(run());
