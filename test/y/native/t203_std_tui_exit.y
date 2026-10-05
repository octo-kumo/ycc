// The other half of t199_std_tui.y's exit: tui.restore_exit(code), where that file
// leaves through tui.restore_all_exit(code).
//
// Both are restore(); exit(code) -- they END the run -- so no single program can
// call both of them and reach anything after it. That is why this is its own
// fixture rather than one more check in t199: a check whose block calls one of
// them never prints, which is exactly how t199 stopped running sixty-odd
// assertions without failing.
//
// What is checked is that the call exists, compiles, takes the exit code, and
// leaves the terminal as it found it -- there is no terminal here, so the line
// below is the whole of what can honestly be asserted.
import tui from "../../../src/y/std/tui.y";

def main() -> long {
    // Nothing to set up. The assertion is the call itself.
    tui.restore();
    puts("restore_exit is the other half, and it returns nothing");
    return 0;
};

tui.restore_exit(main());
