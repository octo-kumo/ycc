// W7/S12: the Node WAV sink.  snd.play() opens 22050 Hz mono through
// y_os_audio_devs/open/write/close, and --audio=FILE.wav records it.  The
// program reads its own recording back after close (the host patches the
// header then) and checks the RIFF lengths, the declared rate and channel
// count, the 400 ms duration and that the samples are not silent; then it
// removes the file so a cwd-relative --audio leaves nothing behind.
import audio;
import fs;
import snd;

def le16(d: [byte], p: long) -> long { d[p] | (d[p + 1] << 8) };
def le32(d: [byte], p: long) -> long {
    d[p] | (d[p + 1] << 8) | (d[p + 2] << 16) | (d[p + 3] << 24)
};

def peak_nonzero(d: [byte]) -> { peak: long, nonzero: long } {
    let peak = 0;
    let nonzero = 0;
    let i = 44;
    while (i + 1 < d.length) {
        let v = le16(d, i);
        if (v >= 32768) { v = v - 65536; };
        let a = if (v < 0) { 0 - v } else { v };
        if (a > 0) { nonzero = nonzero + 1; };
        if (a > peak) { peak = a; };
        i = i + 2;
    };
    { peak: peak, nonzero: nonzero }
};

let path = argv()[1];
let s = audio.tone(22050, 440.0, 400);
print("devs ", snd.available());
print("play ", snd.play(s));
print("rate ", s.rate, " channels ", s.channels);
print("frames ", audio.frames(s), " ms ", audio.frames(s) * 1000 / s.rate);
print("bytes ", s.pcm.length);

let b = fs.read_bytes(path);
if (b == none) {
    print("wav missing");
} else {
    let d = b!;
    let stats = peak_nonzero(d);
    print("wav riff ", d[0] == 82 && d[1] == 73 && d[2] == 70 && d[3] == 70);
    print("wav size ok ", le32(d, 4) == d.length - 8);
    print("wav rate ", le32(d, 24), " channels ", le16(d, 22));
    print("wav data ", le32(d, 40), " file ", d.length - 44);
    print("wav ms ", le32(d, 40) * 1000 / (le32(d, 24) * le16(d, 22) * 2));
    print("wav nonsilent ", stats.nonzero > 0, " peak ", stats.peak);
    print("wav remove ", fs.remove_file(path));
};
