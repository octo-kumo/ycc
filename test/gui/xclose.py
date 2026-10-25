#!/usr/bin/env python3
"""What a window manager does when the user clicks a window's close button: send the
window a WM_DELETE_WINDOW ClientMessage. usage: xclose.py TITLE (python-xlib; DISPLAY)."""
import sys
from Xlib import X, display, protocol

d = display.Display()
want = sys.argv[1].encode()

def find(win):
    n = win.get_wm_name()
    if n is not None and n.encode() == want if isinstance(n, str) else n == want:
        return win
    for c in win.query_tree().children:
        r = find(c)
        if r is not None:
            return r
    return None

w = find(d.screen().root)
if w is None:
    sys.exit("no window named %s" % sys.argv[1])
ev = protocol.event.ClientMessage(
    window=w, client_type=d.intern_atom("WM_PROTOCOLS"),
    data=(32, [d.intern_atom("WM_DELETE_WINDOW"), X.CurrentTime, 0, 0, 0]))
w.send_event(ev, event_mask=0)
d.flush()
d.sync()
