// A second handler on a second line: IRQ0 (the 8254's timer, which QEMU
// ticks at 18.2 Hz whether or not a guest programs it).  The compiler
// unmasks the lines a program declares -- y_pic_remap leaves them all
// masked -- so the only thing this program says about the timer is that it
// has a handler.
import kernel;

let ticks = 0;

irq 0 def timer() -> void {
    kernel.putc(46);
    ticks = ticks + 1;
    if (ticks == 3) { kernel.putc(10); kernel.halt(); };
};

kernel.init();
puts("timer:\n");
kernel.idle();
