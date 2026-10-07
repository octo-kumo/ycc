import kernel;
// expect-error: an irq handler takes no parameters
irq 4 def rx(x: long) -> void { kernel.putc(x); };
kernel.idle();
