// expect-error: write_bytes data:
let data: [long] = [65];
write_bytes("/tmp/ycc-not-written", data, -1);
