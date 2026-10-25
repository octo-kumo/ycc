// bench/y/builder.y — building text: utf8.Builder pushes against `+=` of
// strings and tostring, the two ways a render loop assembles a frame.
import utf8;
def with_builder(n: long) -> long {
    let sb = utf8.builder();
    for i in 0..n {
        utf8.push_cp(sb, 0x2588);
        utf8.push_long(sb, i);
        utf8.push_byte(sb, ' ');
    };
    len(utf8.build(sb))
};
def with_concat(n: long) -> long {
    let s = "";
    for i in 0..n { s += utf8.chr(0x2588); s += tostring(i); s += " "; };
    len(s)
};
print(with_builder(900000) + with_concat(150000));
