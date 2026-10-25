// flags: -D LEVEL=42 -D DEFAULT -D GONE -U GONE -D ON -D ZERO=0 -D EMPTY=
// The build a meta block sees: a value, a defaulted flag (1), -U removing an
// earlier define, ycc_flag's spellings of false, the target fields and the
// constants ycc_consts emits. Without the flags the same file still compiles:
// an absent define is "none" here, as ycc_define says.
#{
    let s = ycc_consts();
    let lv = ycc_define("LEVEL");
    let dv = ycc_define("DEFAULT");
    s += "print(\"level=" + (if (lv == none) { "none" } else { lv! }) + "\");" + chr(10);
    s += "print(\"default=" + (if (dv == none) { "none" } else { dv! }) + "\");" + chr(10);
    s += "print(\"gone=" + (if (ycc_defined("GONE")) { "yes" } else { "no" }) + "\");" + chr(10);
    s += "print(\"on=" + (if (ycc_flag("ON")) { "yes" } else { "no" }) + "\");" + chr(10);
    s += "print(\"zero=" + (if (ycc_flag("ZERO")) { "yes" } else { "no" }) + "\");" + chr(10);
    s += "print(\"empty=" + (if (ycc_flag("EMPTY")) { "yes" } else { "no" }) + "\");" + chr(10);
    s += "print(\"target=\" + YCC_TARGET + \" \" + YCC_OS + \" \" + YCC_ARCH + \" " + YCC.format + "\");" + chr(10);
    s += "print(\"is=" + (if (ycc_target_is("linux,aarch64")) { "y" } else { "n" }) + "\");" + chr(10);
    s += "print(\"quote=\" + " + ycc_quote("a\"b\\c") + ");" + chr(10);
    s
}#
