// struct: a format's value, and which names have a width (m7).
//
// `fill` is the byte to store: a format carries one value per name, and
// "n bytes of one byte" cannot be spelled in a format string at all -- that is
// what fill(n, v) is for. It used to read its value as a count and 0 as the
// byte, so pack("fill", [3]) was three zero bytes (exactly pad(3)) and the
// format could never fill with anything but zero.
//
// `width_of` answers for the fixed widths, and `fill` is one byte. `pad` has
// no width of its own -- its width is the value a format carries -- and a name
// that is not a format has none either; both used to come out of an
// `else { 8 }` that said 8 for everything. Each of those two stops the program
// here, so the width list comes first and the two names that end it come last.
import struct;

print(struct.pack("u8,fill", [65, 66]));
print(struct.pack("fill", [255]));
print(struct.unpack("fill,fill", bytes("AB")));
print(struct.unpack("u8,fill", struct.pack("u8,fill", [65, 66])));

let widths = ["u8", "i8", "u16le", "u16be", "i16le", "i16be", "u32le", "u32be",
              "i32le", "i32be", "u64le", "u64be", "i64le", "i64be", "fill"];
let out: [long] = [];
let k = 0;
while (k < len(widths)) {
    out += struct.width_of(widths[k]);
    k = k + 1;
};
print(out);

// pack still pads with a width, and reading it back is what has no answer
let with_pad = struct.pack("u8,pad,fill", [1, 3, 2]);
print(with_pad);
print(len(with_pad));

// the manual's worked example, verbatim: a header with a width-padded field
// and a filled one, read back field by field and by offset
let hdr = struct.pack("u32be,i16le,pad,fill", [0x01020304, -2, 3, 65]);
print(hdr);
print(struct.unpack("u32be,i16le", hdr));
print(struct.get_u8(hdr, 9));          // the fill's byte: a format cannot skip a pad

print("pad has no width of its own:");
struct.width_of("pad");

print("not reached");
