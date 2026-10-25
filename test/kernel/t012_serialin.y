// Serial INPUT: read one byte from the console and report it.  This is a
// kernel-only case on purpose -- the harness feeds .stdin only for the t*/x*
// cases (the ones built with --target=kernel and booted without -initrd), so a
// user-program case can never receive a byte.
import kernel;

kernel.init();
let c = 0 - 1;
while (c < 0) {
    c = kernel.getc();
};
print("read byte " + tostring(c) + "\n");
kernel.kexit(9);
