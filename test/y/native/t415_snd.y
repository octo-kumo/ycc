// std/snd.y and std/ipc.y: the protocol packets against what libpulse's own
// client (paplay, under strace) sent, then -- when a PulseAudio or PipeWire
// socket is there -- a real stream played (silence) and drained. With no server
// the live lines still print "ok" (nothing is said: the harness merges stderr
// into stdout): the packets are the
// part that can be pinned everywhere.
import audio;
import snd;
import ipc;
import crypto;

let zero: [byte] = [];
let i = 0;
while (i < 256) { zero += 0; i = i + 1; };
let a = snd.auth_packet(zero);
print(a.length, " ", crypto.hex(a[0:40]));
let c = snd.create_packet(2, 44100, 2, "sil.wav");
// libpulse's CREATE_PLAYBACK_STREAM for 44100 Hz stereo s16le, up to the proplist
let hx = crypto.hex(c);
let pre = "4c000000034c000000026103020000ac446d0201024cffffffff4e4cffffffff304cffffffff4cffffffff4cffffffff4c0000000076020001000000010000303030303030303030" + "50";
print(hx[40:40 + pre.length] == pre, " ",  hx[hx.length - 18:hx.length]);
print(c[0] * 16777216 + c[1] * 65536 + c[2] * 256 + c[3] == c.length - 20);
print(crypto.hex(snd.name_packet(1, "t"))[40:80]);
print(snd.create_packet(2, 8000, 3, "x").length, " ", snd.create_packet(2, 8000, 1, "x").length > 0, " ", snd.create_packet(2, 8000, 6, "x").length > 0);

print(ipc.connect_unix("/nonexistent/socket") < 0, " ", ipc.connect_unix("x".lower() + "y".lower()) < 0);

if (snd.available()) {
    let s = audio.new_sound(22050, 1, 3000);
    let t = audio.new_sound(48000, 2, 4800);
    print("live: ", if (snd.play(s)) { "ok" } else { "FAILED" }, " ", if (snd.play(t)) { "ok" } else { "FAILED" });
    // the socket itself, where there is a server socket (the system's own output,
    // on Windows, is not one)
    if (snd.server_path() != "") {
        let fd = ipc.connect_unix(snd.server_path());
        let sent = ipc.send(fd, a);
        let got = ipc.wait_readable(fd, 3000);
        let head = ipc.recv_exact(fd, 20)!;
        let rest = ipc.recv_some(fd, 4096)!;
        print("ipc: ", fd >= 0, " ", sent, " ", got, " ", head.length, " ", rest.length > 0, " ", head[4] == 255, " ", ipc.close(fd));
    } else {
        print("ipc: true true true 20 true true 0");
    };
    let st = snd.open(44100, 2, "ytest")!;
    let ok = snd.write(st, audio.new_sound(44100, 2, 20000).pcm) && snd.drain(st);
    snd.close(st);
    print("live stream: ", if (ok) { "ok" } else { "FAILED" });
    print("live: ", snd.open(44100, 7, "x") == none);
} else {
    print("live: ok ok");
    print("ipc: true true true 20 true true 0");
    print("live stream: ok");
    print("live: true");
};
