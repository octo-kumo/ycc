// pad_left/pad_right/center and a width they cannot fill (m3). A one-byte
// fill asked for 2^63-1 bytes and trapped; a three-byte fill asked for
// (k + 3 - 1) / 3, which overflows to a negative count, so y_str_repeat
// answered "" and the padding silently vanished -- the width came back as the
// string itself, unpadded, with nothing said. Both ask for the same bytes now
// and both say out of memory. The cases that fit come first, because the last
// one traps and ends the program.
print("[", "7".pad_left(9, "ab"), "]");
print("[", "7".pad_right(9, "ab"), "]");
print("[", "7".center(9, "ab"), "]");
// a fill longer than the padding is cut where it overruns
print("[", "7".pad_left(9, "abcdefghijk"), "]");
// a string already that wide, and an empty fill, come back as they are
print("[", "abcdefghij".pad_left(4, "-"), "]", "[", "7".pad_left(4, ""), "]");
print("[", "7".pad_left(2, "x"), "]");

// A width no machine can fill: the three fills used to disagree, and the
// three-byte one answered the string back as if it had padded it.
print("[", "7".pad_left(9223372036854775807, "abc"), "]");