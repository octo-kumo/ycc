// kexit(code): the qemu isa-debug-exit path the harness reads a verdict from.
import kernel;

kernel.init();
puts("exiting 7\n");
kernel.kexit(7);
