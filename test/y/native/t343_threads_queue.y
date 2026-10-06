// A bounded queue: a ring buffer whose EMPTY and FULL conditions are counting
// semaphores, and whose head/tail/count are a mutex's business. Two producers
// and two consumers pass a thousand distinct values through it, and the answer
// is the same whatever order they interleave in -- which is the whole property
// a semaphore is for, and the one a missing post, a missed wakeup or a lost
// update breaks. The `seen` array is the stronger check: every value arrives
// EXACTLY once, so it also catches a value delivered twice, which a checksum
// alone would show as a wrong number but not as a duplicated one.
type Q = { buf: [long], cap: long, head: long, tail: long, count: long, mu: mutex, free: sem, used: sem };

def q_new(cap: long) -> Q {
    let b: [long] = [];
    for i in 0..cap { b += 0; };
    { buf: b, cap: cap, head: 0, tail: 0, count: 0, mu: mutex(), free: sem(cap), used: sem(0) }
};

def q_put(q: Q, v: long) -> void {
    wait q.free;                       // a free slot, or block
    lock q.mu {
        q.buf[q.tail] = v;
        q.tail = (q.tail + 1) % q.cap;
        q.count = q.count + 1;
    };
    post q.used;                       // an item is there
};

def q_get(q: Q) -> long {
    wait q.used;                       // an item, or block
    let v = 0;
    lock q.mu {
        v = q.buf[q.head];
        q.head = (q.head + 1) % q.cap;
        q.count = q.count - 1;
    };
    post q.free;                       // that slot is free again
    v
};

const ITEMS = 1000;
const HALF = 500;
let q = q_new(16);
let seen: [long] = [];
for i in 0..ITEMS { seen += 0; };
let producers: [() -> long] = [];
for p in 0..2 {
    producers += spawn {
        let i = p * HALF;
        let end = i + HALF;
        while (i < end) { q_put(q, i); i = i + 1; };
        0
    };
};
let consumers: [() -> long] = [];
for c in 0..2 {
    consumers += spawn {
        let s = 0;
        let k = 0;
        while (k < HALF) {
            let v = q_get(q);
            s = s + v;
            lock q.mu { seen[v] = 1; };
            k = k + 1;
        };
        s
    };
};
let sum = 0;
foreach (t in consumers) { sum = sum + join t; };
foreach (t in producers) { join t; };
print(sum);
let all = true;
for i in 0..ITEMS { if (seen[i] != 1) { all = false; }; };
print(all);
print(q.count);
print(q.head);
print(q.tail);
