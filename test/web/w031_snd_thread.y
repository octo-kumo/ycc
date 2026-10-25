// W7: a spawned thread writes through the WAV sink while main keeps running.
// Under Node nothing blocks in write, so this pins the program's own ordering
// and counters rather than a stall; after join, main reads the file back and
// checks the data length (complete), the declared rate/channels and that the
// samples are not silent, then removes it.
import audio;
import fs;
import snd;

def sleep_ms(ms: long) -> void {
    let ts: [long; 2] = [0; 2];
    ts[0] = ms / 1000;
    ts[1] = (ms % 1000) * 1000000;
    os_call("y_os_nanosleep", &ts[0]);
};

def le16(d: [byte], p: long) -> long { d[p] | (d[p + 1] << 8) };
def le32(d: [byte], p: long) -> long {
    d[p] | (d[p + 1] << 8) | (d[p + 2] << 16) | (d[p + 3] << 24)
};

let path = argv()[1];
let chunks = 0;
let bytes = 0;
let done = 0;
let ticks = 0;

let t = spawn {
    let st = snd.open(22050, 1, "thread")!;
    let tone = audio.tone(22050, 330.0, 50);
    let i = 0;
    while (i < 8) {
        if (!snd.write(st, tone.pcm)) { done = -1; i = 8; }
        else { chunks = chunks + 1; bytes = bytes + tone.pcm.length; i = i + 1; };
    };
    snd.drain(st);
    snd.close(st);
    if (done == 0) { done = 1; };
    0
};

// Main keeps running (and sleeping) while the thread writes.
while (done == 0) { ticks = ticks + 1; sleep_ms(1); };
join t;
print("chunks ", chunks);
print("done ", done);
print("main ticks > 0 ", ticks > 0);
print("bytes ", bytes);

let b = fs.read_bytes(path);
if (b == none) {
    print("wav missing");
} else {
    let d = b!;
    let nz = 0;
    let i = 44;
    while (i + 1 < d.length) {
        let v = le16(d, i);
        if (v != 0) { nz = nz + 1; };
        i = i + 2;
    };
    print("wav data ", le32(d, 40), " expected ", bytes);
    print("wav complete ", le32(d, 40) == bytes && d.length == 44 + bytes);
    print("wav rate ", le32(d, 24), " channels ", le16(d, 22));
    print("wav nonsilent ", nz > 0);
    print("wav remove ", fs.remove_file(path));
};
