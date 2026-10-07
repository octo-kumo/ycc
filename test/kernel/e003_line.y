import kernel;
// expect-error: an irq line is 0..15
irq 16 def rx() -> void { };
kernel.idle();
