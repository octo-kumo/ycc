// flags: --gc=auto --strict-heap
import memstat;
// A loop that allocates, and from which nothing a turn makes can be reached
// after the turn, gets a region from the compiler (escape.y, `region$auto`):
// its turns' allocations are freed between turns (every 64 KiB) and when it
// ends. With no collector at all, the
// first loop churns about a gigabyte in a few megabytes, and --strict-heap has
// nothing to say about it. A loop that keeps what it makes is left alone, and
// still draws its warnings.

def words(i: long) -> [str] {
    let s = "w" + tostring(i) + " x" + tostring(i * 7) + " y";
    s.split(" ")
}

let total = 0;
for i in 0..200000 {
    let ws = words(i);
    let row = [i; 600];
    total += ws[1].length + row[599] % 3;
}
print(total);

// Kept: `names` outlives the loop, so these turns are not regions.
let names: [str] = [];
for i in 0..3 {
    names += "n" + tostring(i); // expect-warning: heap: this string concatenation repeats in a loop // expect-warning: heap: the call to 'tostring' repeats in a loop
}
print(names);

// A turn that returns, breaks or continues out of the region leaves it.
def first_long(xs: [str]) -> long {
    foreach (x in xs) {
        let parts = x.split(":");
        if (parts.length > 1) { return parts[1].length; };
        if (parts[0] == "stop") { break; };
    };
    -1
}
print(first_long(["a", "b:cc", "d"]) + first_long(["stop", "e:f"]));

// An empty body whose condition allocates: no statement to put the region in,
// so the loop stays the collector's (this once indexed an empty list).
let ticks = 0;
def step() -> bool {
    ticks += 1;
    ("t" + tostring(ticks)).length < 4 // expect-warning: heap: this string concatenation repeats: 'step' is called in a loop // expect-warning: heap: the call to 'tostring' repeats: 'step' is called in a loop
}
while (step()) { }
print(ticks);

let rss = memstat.rss_kb();
print(rss < 65536);
