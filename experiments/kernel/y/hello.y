// The smallest kernel: bring COM1 up, say something, stop.
import kernel;

kernel.init();
puts("ycc --kernel: hello from Y\n");
kernel.halt();
