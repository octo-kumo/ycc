// W7/S12: the page's AudioContext.  snd opens 48 kHz mono through the private
// audio syscalls; browser.test.mjs then reads the host's stats: the context
// reaches "running", the worklet's consumed-frame reports arrive, the samples
// are not silent, and the gesture/mute hooks work.
import audio;
import snd;

def sleep_ms(ms: long) -> void {
    let ts: [long; 2] = [0; 2];
    ts[0] = ms / 1000;
    ts[1] = (ms % 1000) * 1000000;
    os_call("y_os_nanosleep", &ts[0]);
};

let st = snd.open(48000, 1, "w112")!;
let tone = audio.tone(48000, 440.0, 60);
let i = 0;
while (i < 8) { snd.write(st, tone.pcm); i = i + 1; };
snd.drain(st);
// Give the worklet time to render and report the frames it consumed.
sleep_ms(350);
snd.close(st);
print("devs ", snd.available());
print("wrote ", 8 * 60, " ms");
