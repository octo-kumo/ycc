// expect-error: 'native def' is 'ndef' now: write 'ndef name(...) -> T;'
// The two-word spelling is gone: `native` is an ordinary identifier now, so
// without the parser's own diagnostic the report is "undefined variable
// 'native'" and "expected ';', got 'my_cmp'" -- two errors that never name
// the spelling that works.
native def my_cmp(a: str, b: str) -> long = "y_str_cmp";
print(1);
