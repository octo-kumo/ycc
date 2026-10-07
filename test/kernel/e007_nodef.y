import kernel;
// expect-error: expected 'def' after 'irq N': an irq handler is 'irq N def name() -> void { ... }'
irq 4 rx() { };
kernel.idle();
