// flags: --warnings=all
// The injected YCC declarations are in the generator, not the program: a meta
// file that does not use them compiles with no new warning, and its pieces are
// exactly what the block wrote.
def twice(n: long) -> long { n * 2 };
#{
    let s = "";
    for i in 0..2 { s += "print(\"n=" + tostring(twice(i)) + "\");" + chr(10); };
    s
}#
