import kernel;
// expect-error: an irq handler returns void
irq 4 def rx() -> long { 0 };
kernel.idle();
