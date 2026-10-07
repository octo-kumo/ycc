// Echo every byte typed at the serial console, from an IRQ4 handler.
//
// `irq 4 def` is the language's interrupt handler: the line is bound at the
// declaration, the checker requires a no-parameter void signature, and the
// compiler generates the stub (save the caller-saved registers, call this,
// acknowledge the 8259, iretq) and the IDT entry that points at it.
import kernel;

irq 4 def serial_rx() -> void {
    let c = kernel.getc();
    if (c == 13) { kernel.putc(10); };
    kernel.putc(c);
};

kernel.init();
puts("ycc --kernel: serial echo -- type something\n");
kernel.serial_irq_on();
kernel.idle();
