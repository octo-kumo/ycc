// kbd -- the PS/2 controller (i8042): a keyboard on IRQ 1 and a mouse on IRQ 12.
//
// qemu has one on every PC, so a plain `-vga std` boot types and points with no
// extra device. The controller translates the keyboard to scancode set 1, whose
// make codes are Linux's key codes below 0x59; an E0-prefixed key is mapped by
// hand (the cursor block, the right-hand Ctrl and Alt, keypad Enter and /). The
// mouse is put in IntelliMouse mode when it answers (a wheel: 4-byte packets).
// Both report to input.input_event.
import kernel;
import input from "./input.y";

const KB_DATA = 96;
const KB_CMD = 100;

const BTN_LEFT = 272;
const BTN_RIGHT = 273;
const BTN_MIDDLE = 274;

let kb_e0 = false;
let kb_skip = 0;

let ms_pkt: [long; 4] = [0; 4];
let ms_n = 0;
let ms_size = 3;
let ms_btn = 0;

/** Wait for the controller to take a byte (false: it never did). */
def kbd_wait_in() -> bool {
    let n = 0;
    while (n < 100000) {
        if ((kernel.inb(KB_CMD) & 2) == 0) { return true; };
        n = n + 1;
    };
    false
};

/** Wait for a byte to read (false: none came). */
def kbd_wait_out() -> bool {
    let n = 0;
    while (n < 100000) {
        if ((kernel.inb(KB_CMD) & 1) != 0) { return true; };
        n = n + 1;
    };
    false
};

def kbd_cmd(c: long) -> void {
    if (kbd_wait_in()) { kernel.outb(KB_CMD, c); };
};

def kbd_data(c: long) -> void {
    if (kbd_wait_in()) { kernel.outb(KB_DATA, c); };
};

/** The next byte from the controller, or -1. */
def kbd_read() -> long {
    if (kbd_wait_out()) { kernel.inb(KB_DATA) } else { 0 - 1 }
};

/** Throw away whatever the controller has queued. */
def kbd_flush() -> void {
    let n = 0;
    while ((kernel.inb(KB_CMD) & 1) != 0 && n < 64) {
        kernel.inb(KB_DATA);
        n = n + 1;
    };
};

/** A command to the mouse; its answer (0xFA is the ack), or -1. */
def kbd_mouse(c: long) -> long {
    kbd_cmd(212);
    kbd_data(c);
    kbd_read()
};

/** Boot: set the controller up with its interrupts off, then turn them on. */
def kbd_init() -> void {
    input.input_init();
    // no controller (a machine without one reads 0xFF from the status port): nothing to set up
    if (kernel.inb(KB_CMD) == 255) { return; };
    kbd_cmd(173);
    kbd_cmd(167);
    kbd_flush();
    kbd_cmd(32);
    let cfg = kbd_read();
    if (cfg < 0) { return; };
    kbd_cmd(96);
    kbd_data((cfg | 64) & 204);
    kbd_cmd(174);
    kbd_cmd(168);
    kbd_data(244);
    kbd_read();
    if (kbd_mouse(246) == 250) {
        kbd_mouse(243);
        kbd_mouse(200);
        kbd_mouse(243);
        kbd_mouse(100);
        kbd_mouse(243);
        kbd_mouse(80);
        if (kbd_mouse(242) == 250) {
            if (kbd_read() == 3) { ms_size = 4; };
        };
        kbd_mouse(244);
    };
    kbd_flush();
    kbd_cmd(96);
    kbd_data(((cfg | 64) & 204) | 3);
};

/** A keyboard byte: a scancode (set 1), with the E0 and E1 prefixes. */
def kbd_key(b: long) -> void {
    if (kb_skip > 0) { kb_skip = kb_skip - 1; return; };
    if (b == 225) { kb_skip = 5; return; };
    if (b == 224) { kb_e0 = true; return; };
    let down = (b & 128) == 0;
    let code = b & 127;
    let ext = kb_e0;
    kb_e0 = false;
    if (ext) {
        if (code == 28) { code = 96; }
        else if (code == 29) { code = 97; }
        else if (code == 53) { code = 98; }
        else if (code == 56) { code = 100; }
        else if (code == 71) { code = 102; }
        else if (code == 72) { code = 103; }
        else if (code == 73) { code = 104; }
        else if (code == 75) { code = 105; }
        else if (code == 77) { code = 106; }
        else if (code == 79) { code = 107; }
        else if (code == 80) { code = 108; }
        else if (code == 81) { code = 109; }
        else if (code == 82) { code = 110; }
        else if (code == 83) { code = 111; }
        else { return; };
    };
    if (code == 0 || code > 111) { return; };
    let v = 0;
    if (down) { v = 1; };
    input.input_event(input.EV_KEY, code, v);
};

/** A mouse byte; every whole packet becomes button, motion and wheel events. */
def kbd_mouse_byte(b: long) -> void {
    if (ms_n == 0 && (b & 8) == 0) { return; };
    ms_pkt[ms_n] = b;
    ms_n = ms_n + 1;
    if (ms_n < ms_size) { return; };
    ms_n = 0;
    let f = ms_pkt[0];
    let dx = ms_pkt[1] - ((f << 4) & 256);
    let dy = ms_pkt[2] - ((f << 3) & 256);
    let btn = f & 7;
    let ch = btn ^ ms_btn;
    ms_btn = btn;
    if ((ch & 1) != 0) { input.input_event(input.EV_KEY, BTN_LEFT, btn & 1); };
    if ((ch & 2) != 0) { input.input_event(input.EV_KEY, BTN_RIGHT, (btn >> 1) & 1); };
    if ((ch & 4) != 0) { input.input_event(input.EV_KEY, BTN_MIDDLE, (btn >> 2) & 1); };
    if (dx != 0) { input.input_event(input.EV_REL, 0, dx); };
    if (dy != 0) { input.input_event(input.EV_REL, 1, 0 - dy); };
    if (ms_size == 4) {
        let w = ms_pkt[3] & 15;
        if (w >= 8) { w = w - 16; };
        if (w != 0) { input.input_event(input.EV_REL, 8, 0 - w); };
    };
    input.input_event(input.EV_SYN, 0, 0);
};

/** IRQ 1 and IRQ 12: drain the controller, routing each byte by the status's aux bit. */
def kbd_on_irq() -> void {
    let n = 0;
    while (n < 64) {
        let st = kernel.inb(KB_CMD);
        if ((st & 1) == 0) { return; };
        let b = kernel.inb(KB_DATA);
        if ((st & 32) != 0) { kbd_mouse_byte(b); } else { kbd_key(b); };
        n = n + 1;
    };
};
