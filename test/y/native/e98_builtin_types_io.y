// expect-error: 14:6: error: eputs supports long/bool/str, got [long]
// expect-error: 15:5: error: puts supports long/bool/str, got [long]
// expect-error: 16:6: error: sleep duration: expected long, got str
// expect-error: 17:5: error: exit code: expected long, got str
// (read_file, write_file and write_bytes are std/fs.y defs: e143)
//
//
//
//
//
//
// expect-error: 25:9: error: ptr_addr needs a pointer, got long
// expect-error: 26:8: error: syscall arg 1 must be long/bool/str/*T, got float
eputs([1]);
puts([1]);
sleep("bad");
exit("bad");
0;
0;
0;
0;
0;
0;
0;
ptr_addr(1);
syscall(1, 1.0);
