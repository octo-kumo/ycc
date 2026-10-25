import memstat;
// An automatic region (escape.y) has no collector inside it, so a turn that
// makes a lot of garbage would keep all of it until the turn ends. Once the
// arena of automatic regions passes 32 MiB it is handed to the collector
// (arch/regions.s y_region_spill): its chunks become the collector's, the turn
// goes on in the collector's heap, and the garbage is collected as usual. Each
// turn below makes about 200 MB of dead strings (the inner loop rebinds `s`,
// so it is no region of its own), and live values made before the hand-over
// stay valid after it.

def turn(i: long) -> long {
    let head = "h" + tostring(i);
    let s = "";
    for j in 0..20000 { s = s + "x"; }
    let tail = [i, i + 1, i + 2];
    head.length + s.length + tail[2]
}

let total = 0;
for i in 0..4 {
    let kept = "k" + tostring(i);
    total += turn(i) + kept.length;
}
print(total);
let rss = memstat.rss_kb();
print(rss < 196608);
