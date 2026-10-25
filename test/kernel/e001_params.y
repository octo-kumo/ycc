import kernel;
// expect-error: an irq handler takes no parameters (it is called from the interrupt entry)
irq 4 def rx(x: long) -> void { kernel.putc(x); };
kernel.idle();
