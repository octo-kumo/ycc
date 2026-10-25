// console -- where the terminal's output goes, and which view the machine shows.
//
// Serial is always a sink: it is the console the test suite and a headless boot
// use, and a byte written here is on the line whatever else is attached. A screen
// sink (vt.y) joins it when a display device is found. Input sources (the UART,
// the keyboard) do not live here: each calls tty.tty_input or input.input_event.
//
// The view is TEXT (the kernel's terminal draws on the screen and the keyboard
// types into the tty) or GUI (a program owns the pixels and reads /dev/input).
// F1 or F12 toggles it (input.y); the terminal keeps its screen state either way.
import kernel;
import vt from "./vt.y";
import fb from "./fb.y";

const CON_TEXT = 0;
const CON_GUI = 1;

let con_mode = 0;

/** One output byte to every sink. */
def con_putc(c: long) -> void {
    kernel.putc(c);
    vt.vt_putc(c);
};

/** What the terminal's queries (cursor position, device attributes) asked to be typed back. */
def con_take_reply() -> str { vt.vt_take_reply() };

def con_get_mode() -> long { con_mode };

/** Switch the view. */
def con_set_mode(m: long) -> void {
    if (m == con_mode) { return; };
    // the GUI view needs a GUI: until a program has opened /dev/fb0 there is none to show
    if (m == CON_GUI && fb.fb_gui_phys_addr() == 0) { return; };
    con_mode = m;
    if (m == CON_TEXT) {
        fb.fb_show(1);
        vt.vt_show();
    } else {
        fb.fb_show(2);
    };
};

def con_toggle() -> void {
    if (con_mode == CON_TEXT) { con_set_mode(CON_GUI); } else { con_set_mode(CON_TEXT); };
};
