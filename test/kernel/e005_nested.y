import kernel;
def outer() -> void {
    // expect-error: an irq handler must be declared at the top level
    irq 4 def rx() -> void { };
};
kernel.idle();
