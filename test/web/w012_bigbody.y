// W4/S4: a huge body.  The def below is generated at compile time: 3,000
// if/else blocks and a while loop inside each one, which is ~30,000
// statements and ~9,000 code labels.  The chunker has to split it at
// CHUNK_MAX_INSNS (8192) and CHUNK_MAX_CASES (2048), every split has to keep
// its fall-through and its tokens right, and the answer has to be the one a
// native build gives.
#{
    let out = "def big() -> long {\n    let a = 12345;\n    let b = 1;\n";
    let i = 0;
    while (i < 3000) {
        out += "    a = a * 1103515245 + 12345;\n";
        out += "    b = b + a;\n";
        out += "    if (a < 0) {\n        a = a + 7;\n        b = b - 1;\n";
        out += "    } else {\n        a = a - 3;\n        b = b + 1;\n    };\n";
        out += "    let t = a & 1023;\n";
        out += "    while (t > 100) {\n        t = t - 7;\n        b = b + t;\n    };\n";
        out += "    b = b + t;\n";
        out += "    a = a + t;\n";
        i++;
    };
    out += "    a + b\n};\n";
    out += "print(big(), \"\\n\");\n";
    out
}#
