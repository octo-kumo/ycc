// A trap in a kernel: the prelude's y_div_zero is replaced by one that
// writes the message to COM1 and stops, instead of calling write(2).
import kernel;

kernel.init();
puts("before\n");
let z = 0;
print(1 / z);
puts("after\n");
