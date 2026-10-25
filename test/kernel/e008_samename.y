import kernel;
irq 4 def rx() -> void { };
// expect-error: 'rx' is declared for irq line 4 twice
irq 5 def rx() -> void { };
kernel.idle();
