// expect-error: error: the meta generator emitted more than 33554432 bytes
// e184 stops just past the 32 MiB cap, which the compiler can afford to
// collect and then throw away. This one emits FAR past it -- seven times --
// because the bug it gates is not the cap CHECK but what the reader
// does before reaching it: it kept every byte, and the C copy boxes one Y
// value per byte (measured: ~24 bytes of heap per byte collected), so
// collecting a 234 MB emission cost it ~5 GB, over the 3.5 GiB cap every
// test process runs under, and it died with "runtime error: out of memory"
// where the Y copy reported the cap. The reader now stops KEEPING bytes once
// the cap is passed (and drains the pipe, because the child is still writing),
// so both copies answer with the one diagnostic above. Found by the fuzzer,
// seed 9432, as a mutation of e184; the old e184 could not catch it, because
// 37 MB collects to well under the cap.
def huge() -> str {
    let line = "// 0123456789012345678901234567890123456789012345678901234567890123\n";
    let out = "";
    for i in 0..3600000 { out += line; };
    out
};
let x = #{ huge() }#;
print(1);
