// uname [-a] -- the system name (yunix); -a: name, host, release, version, machine.
import ulib;
let a = argv();
let u = ulib.uname();
if (len(a) > 1 && a[1] == "-a") {
    puts(join(u, " ") + "\n");
} else {
    puts(u[0] + "\n");
};
