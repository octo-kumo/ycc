// expect-error: 11:5: error: puts takes exactly 1 argument
// expect-error: 12:5: error: exit takes exactly 1 argument
// expect-error: 13:5: error: argv takes no arguments
// expect-error: 14:10: error: read_file takes exactly 1 argument (path)
// expect-error: 15:6: error: bytes takes exactly 1 argument (string)
// expect-error: 16:11: error: from_bytes takes exactly 1 argument (byte array)
// expect-error: 17:11: error: write_file takes exactly 2 arguments (path, content)
// expect-error: 18:12: error: write_bytes takes exactly 3 arguments (path, bytes, mode)
// expect-error: 19:9: error: ptr_addr takes exactly 1 argument (pointer)
// expect-error: 20:8: error: syscall needs 1-7 arguments (number + up to 6 args)
puts();
exit();
argv(1);
read_file();
bytes();
from_bytes();
write_file("");
write_bytes("", []);
ptr_addr();
syscall();
