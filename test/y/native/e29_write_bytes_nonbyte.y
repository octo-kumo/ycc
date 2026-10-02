// expect-error: 'fs.write_bytes' arg 1: expected [byte], got [long]
// A [long] is no [byte]: the layouts differ, so nothing converts it.
import fs;
let data: [long] = [65];
fs.write_bytes("/tmp/ycc-not-written", data, -1);
