// expect-error: 11:5: error: puts takes exactly 1 argument
// expect-error: 12:5: error: exit takes exactly 1 argument
// expect-error: 13:5: error: argv takes no arguments
// (read_file, write_file and write_bytes are std/fs.y defs: e143)
// expect-error: 15:6: error: bytes takes exactly 1 argument (string)
// expect-error: 16:11: error: from_bytes takes exactly 1 argument (byte array)
//
//
// expect-error: 19:9: error: ptr_addr takes exactly 1 argument (pointer)
// expect-error: 20:8: error: syscall needs 1-7 arguments (number + up to 6 args)
puts();
exit();
argv(1);
0;
bytes();
from_bytes();
0;
0;
ptr_addr();
syscall();
