// Serial receive through an IRQ4 handler written in Y: every byte typed at
// the console is echoed back, with CR translated to LF.
import kernel;

irq 4 def serial_rx() -> void {
    let c = kernel.getc();
    if (c == 13) { kernel.putc(10); } else { kernel.putc(c); };
};

kernel.init();
puts("echo:\n");
kernel.serial_irq_on();
kernel.idle();
