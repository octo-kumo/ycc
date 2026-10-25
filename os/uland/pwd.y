// pwd -- the working directory.
import ulib;
let d = ulib.getcwd();
// a kernel with no getcwd has one directory to be in
puts((if (d == "") { "/" } else { d }) + "\n");
