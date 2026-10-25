import kernel;
// expect-error: an irq line is 0..15 (the 8259's lines, remapped to IDT vectors 32..47)
irq 16 def rx() -> void { };
kernel.idle();
