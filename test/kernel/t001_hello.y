// The smallest kernel: bring COM1 up, print, stop.  `puts` reaches the
// serial port through y_os_write, which the kernel target replaces.
import kernel;

kernel.init();
puts("hello from a Y kernel\n");
print(6 * 7);
kernel.halt();
