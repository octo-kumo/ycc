// sndtone -- play 300 ms of 440 Hz through std/snd (the Pulse socket in $XDG_RUNTIME_DIR),
// as a program does: pulsed mixes it into /dev/dsp.
import snd;

def tone(n: long) -> [byte] {
    let out: [byte] = [];
    let i = 0;
    while (i < n) {
        // a triangle wave, period 50 samples at 22050 Hz = 441 Hz
        let ph = i % 50;
        let v = (if (ph < 25) { ph * 800 - 10000 } else { (50 - ph) * 800 - 10000 });
        let u = v & 65535;
        out += u & 255;
        out += u >> 8;
        i += 1;
    };
    out
};

if (!snd.available()) {
    puts("sndtone: no audio server\n");
    exit(1);
};
let s = snd.open(22050, 1, "sndtone");
if (s == none) {
    puts("sndtone: cannot open a stream\n");
    exit(1);
};
puts("sndtone: stream open\n");
let ok = snd.write(s!, tone(6615));
snd.drain(s!);
snd.close(s!);
puts(if (ok) { "sndtone: played\n" } else { "sndtone: write failed\n" });
