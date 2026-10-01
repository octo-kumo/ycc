// expect-error: 14:6: error: eputs supports long/bool/str, got [long]
// expect-error: 15:5: error: puts supports long/bool/str, got [long]
// expect-error: 16:6: error: sleep duration: expected long, got str
// expect-error: 17:5: error: exit code: expected long, got str
// expect-error: 18:10: error: read_file path: expected str, got long
// expect-error: 19:11: error: write_file path: expected str, got long
// expect-error: 20:11: error: write_file content: expected str, got bool
// expect-error: 21:12: error: write_bytes path: expected str, got long
// expect-error: 22:12: error: write_bytes data: expected [byte], got [long]
// expect-error: 23:12: error: write_bytes mode: expected long, got str
// expect-error: 24:12: error: write_bytes needs a byte array, got long
// expect-error: 25:9: error: ptr_addr needs a pointer, got long
// expect-error: 26:8: error: syscall arg 1 must be long/bool/str/*T, got float
eputs([1]);
puts([1]);
sleep("bad");
exit("bad");
read_file(1);
write_file(1, false);
write_file("out", false);
write_bytes(1, [1], "bad");
write_bytes("out", [1], 0);
write_bytes("out", [c'a'], "bad");
write_bytes("out", 1, 0);
ptr_addr(1);
syscall(1, 1.0);
