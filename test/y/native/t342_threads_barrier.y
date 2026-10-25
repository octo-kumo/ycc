// Cross-thread visibility, with the two ways it is usually got wrong written
// down next to the way that works.
//
// A BARRIER is not `post s; wait s;` -- a semaphore's post can satisfy the
// poster's OWN wait, so a thread that runs ahead posts, passes itself, and
// reads the other threads' cells before they wrote them (this fixture was
// written that way first, and the sum below came out 128, 129, 148 over three
// runs instead of 288). The barrier is a count under the mutex and N posts by
// whoever arrives last, so every waiter -- that thread included -- is released
// only once all N have arrived.
const N = 8;
let phase: [long] = [];
for i in 0..N { phase += 0; };
let mu = mutex();
let arrived = sem(0);
let met = 0;
let ts: [() -> long] = [];
for w in 0..N {
    ts += spawn {
        lock mu {
            phase[w] = w + 1;
            met = met + 1;
            if (met == N) { let i = 0; while (i < N) { post arrived; i = i + 1; }; };
        };
        wait arrived;
        let sum = 0;
        for i in 0..N { sum = sum + phase[i]; };
        sum
    };
};
let total = 0;
foreach (t in ts) { total = total + join t; };
print(total);
print(phase);

// A one-slot mailbox is not one semaphore either: the producer would overwrite
// the slot before the consumer read it, and the consumer would then read the
// same value twice and miss another (that version summed 5218-5307 over three
// runs where the answer is 4950). It takes TWO -- one saying "a message is
// there", one saying "the previous one was taken" -- or a queue.
type Msg = { n: long, text: str };
let box: [Msg] = [{n: 0, text: ""}];
let sent = sem(0);
let taken = sem(1);
let producer = spawn {
    let i = 0;
    while (i < 100) {
        wait taken;
        box[0] = {n: i, text: "m" + tostring(i)};
        post sent;
        i = i + 1;
    };
    0
};
let got = 0;
let last = "";
let j = 0;
while (j < 100) {
    wait sent;
    let m = box[0];
    got = got + m.n;
    last = m.text;
    post taken;
    j = j + 1;
};
join producer;
print(got);
print(last);

// Two mutexes, taken in the same order by every thread: no deadlock, and both
// counters agree at the end.
let a = mutex();
let b = mutex();
let ca = 0;
let cb = 0;
let ms: [() -> long] = [];
for k in 0..6 {
    ms += spawn {
        let i = 0;
        while (i < 2000) {
            lock a { ca = ca + 1; };
            lock b { cb = cb + 1; };
            i = i + 1;
        };
        0
    };
};
foreach (t in ms) { join t; };
print(ca);
print(cb);
