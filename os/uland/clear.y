// clear -- clear the screen (home the cursor, erase it all, and the scrollback).
import ulib;
let esc = chr(27);
ulib.write(1, esc + "[H" + esc + "[2J" + esc + "[3J");
