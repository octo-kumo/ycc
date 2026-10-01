import struct;

def run(n: long) -> long {
    let total = 0;
    let i = 0;
    while (i < n) {
        let packed = struct.pack("u32le,i32be,u64le", [i, 0 - i, i * 1000003]);
        let values = struct.unpack("u32le,i32be,u64le", packed);
        total = total + values[0] + values[1] + values[2];
        total = total
            + struct.get_u32le(packed, 0)
            + struct.get_i32be(packed, 4)
            + struct.get_u64le(packed, 8);
        i = i + 1;
    };
    total
};

print(run(50000));
