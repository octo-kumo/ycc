import fs;

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
    let fd = fs.open_file(path, "w");
    let i = 0;
    let written = 0;
    while (i < chunks) {
        if (fs.write_text(fd, chunk)) { written = written + size; 0 } else { 0 };
        i = i + 1;
    };
    fs.close_file(fd);

    let input = fs.open_file(path, "r");
    let buffer: [long; 8192] = [0; 8192];
    let total = 0;
    let checksum = 0;
    let reading = true;
    while (reading) {
        let n = syscall(0, input, &buffer[0], size);
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
    fs.close_file(input);
    fs.remove_file(path);
    if (written != chunks * size || total != written) { exit(1); 0 } else { 0; };
    checksum
};

print(run());
