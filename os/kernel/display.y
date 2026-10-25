// display -- bring the screen up and keep the terminal's size in step with it.
//
// `display_init` (boot) looks for a display (fb.y), starts it at the size asked for on the
// kernel command line (`fbw=` `fbh=`; 0: what the host window is, else 1280x800), attaches the
// text terminal (vt.y) as a second sink of the console and starts the virtio input devices.
// Without a display nothing here does anything and the machine is the serial console it always was.
// `display_tick` is the clock's hook: it reads the virtio input queues and notices the host
// resizing the window, which resizes the terminal (rows and columns, SIGWINCH to the foreground
// group) and tells the GUI (input.y queues a display-changed event).
import kernel;
import fb from "./fb.y";
import vt from "./vt.y";
import tty from "./tty.y";
import vinput from "./vinput.y";
import input from "./input.y";

let dp_tick = 0;
let dp_ready = false;

/** True once `display_init` has finished: before that the clock handler must not touch the screen
(the setup commands and the frame flushes share one virtio queue). */
def display_ready() -> bool { dp_ready };

/** Start the display and the VT; false when there is no display. */
def display_init(w: long, h: long) -> bool {
    if (!fb.fb_init(w, h)) { return false; };
    if (!vt.vt_init()) { return false; };
    tty.tty_set_size(vt.vt_get_rows(), vt.vt_get_cols());
    vinput.vinput_init();
    fb.fb_show(1);
    dp_ready = true;
    true
};

/** The display changed size: the terminal follows. */
def display_resized() -> void {
    vt.vt_resize();
    tty.tty_set_size(vt.vt_get_rows(), vt.vt_get_cols());
    tty.tty_winch();
    input.input_display_changed();
};

/** Called every clock tick. */
def display_tick() -> void {
    if (!dp_ready) { return; };
    vinput.vinput_poll();
    dp_tick = dp_tick + 1;
    if (dp_tick >= 32) {
        dp_tick = 0;
        if (fb.fb_poll()) { display_resized(); };
    };
};
