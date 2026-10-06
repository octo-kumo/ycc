// SUGGESTIONS.md 4: a checked integer parse. tolong() guesses silently, so a
// caller cannot tell "not a number" from 0 ("12abc" is 12, "" is 0, "0x10" is
// 0) and a value too large wraps instead of failing. parse_long answers none.
import math;
print(math.parse_long("0")!);
print(math.parse_long("-7")!);
print(math.parse_long("+42")!);
print(math.parse_long("9223372036854775807")!);
print(math.parse_long("-9223372036854775808")!);
print(math.parse_long("12abc") == none);
print(math.parse_long("") == none);
print(math.parse_long(" 12 ") == none);
print(math.parse_long("0x10") == none);
print(math.parse_long("-") == none);
print(math.parse_long("+") == none);
print(math.parse_long("9223372036854775808") == none);
print(math.parse_long("-9223372036854775809") == none);
print(math.parse_long("999999999999999999999") == none);
print(math.parse_long("1_000") == none);
// What tolong does with the same inputs, for the contrast the entry is about.
print(tolong("12abc"), " ", tolong(""), " ", tolong(" 12 "), " ", tolong("0x10"));
