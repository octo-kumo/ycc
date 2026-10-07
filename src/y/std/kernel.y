// std/kernel.y -- the freestanding half of std, for `ycc --kernel`.
//
// A kernel program imports this and nothing else that reaches a kernel: the
// user-space units (fs, net, exec, ...) are refused by the compiler in kernel
// mode (native.y's kernel_std_denied), because every one of them is a Linux
// syscall away from working.  What is here is the machine's own surface --
// COM1, the 8259, the IDT -- plus one definition per interrupt line, so a
// handler declaration can name the line instead of spelling it.
//
// The primitives are `ndef`s into src/y/arch/kernel.s, the same bridge
// std/math.y uses for its float kernels.  `y_` is the reserved prefix, so
// these keep their bare label names however a program refers to them.
//
// Output needs nothing from this file: `print`/`puts` reach `y_os_write`,
// which in a kernel IS the serial port (arch/kernel.s replaces it), so the
// ordinary std formatting works unchanged.

// ── the interrupt lines ─────────────────────────────────────────────────
// One definition per 8259 line, in the order the chips number them.
const IRQ_TIMER = 0;
const IRQ_KEYBOARD = 1;
const IRQ_CASCADE = 2;
const IRQ_COM2 = 3;
const IRQ_COM1 = 4;
const IRQ_LPT2 = 5;
const IRQ_FLOPPY = 6;
const IRQ_LPT1 = 7;
const IRQ_CMOS = 8;
const IRQ_FREE1 = 9;
const IRQ_FREE2 = 10;
const IRQ_FREE3 = 11;
const IRQ_MOUSE = 12;
const IRQ_FPU = 13;
const IRQ_ATA1 = 14;
const IRQ_ATA2 = 15;

// ── the machine primitives (src/y/arch/kernel.s) ────────────────────────
ndef y_serial_init() -> long = "y_serial_init";
ndef y_serial_irq_on() -> long = "y_serial_irq_on";
ndef y_serial_putb(c: long) -> long = "y_serial_putb";
ndef y_serial_getb() -> long = "y_serial_getb";
ndef y_pic_remap() -> long = "y_pic_remap";
ndef y_pic_eoi(irq: long) -> long = "y_pic_eoi";
ndef y_idt_fill_default() -> long = "y_idt_fill_default";
ndef y_idt_load() -> long = "y_idt_load";
ndef y_kernel_sti() -> long = "y_kernel_sti";
ndef y_kernel_cli() -> long = "y_kernel_cli";
ndef y_kernel_halt() -> long = "y_kernel_halt";

// ── the surface a kernel program uses ───────────────────────────────────

// Bring the console and the interrupt controllers up and load an IDT whose
// every vector answers '?' and stops.  Call it first; a program that declares
// `irq` handlers gets those installed on top by the code the compiler emits
// (native.y's kernel_irq_text), which runs after this.
def init() -> void {
    y_serial_init();
    y_pic_remap();
    y_idt_fill_default();
    y_idt_load();
};

// Open COM1's receiver interrupt (IRQ4).  Until this is called the port is
// polled-only and the line stays masked.
def serial_irq_on() -> void {
    y_serial_irq_on();
};

// Acknowledge line `irq` (0..15) on the 8259s.
def eoi(irq: long) -> void {
    y_pic_eoi(irq);
};

def sti() -> void {
    y_kernel_sti();
};

def cli() -> void {
    y_kernel_cli();
};

// Stop the machine.
def halt() -> void {
    y_kernel_halt();
};

// One byte out (waiting for the transmitter), one byte in (waiting for the
// receiver).  `print`/`puts` are the bulk output path.
def putc(c: long) -> void {
    y_serial_putb(c);
};

def getc() -> long {
    y_serial_getb()
};
