import kernel;
irq 4 def rx() -> void { };
// expect-error: irq line 4 already has a handler
irq 4 def ry() -> void { };
kernel.idle();
