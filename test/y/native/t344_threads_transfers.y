// Money is conserved. Twelve accounts, eight threads, 2000 transfers each:
// every transfer takes the two accounts' mutexes in INDEX order, so two
// threads moving value in opposite directions take them in the same order and
// cannot deadlock. The intermediate balances are different on every run and
// nothing prints them -- what is checked is the invariant that survives any
// interleaving, the total, plus the per-account sums the threads report.
//
// This is the shape a mutex exists for: the critical section is a pair of
// objects, so the lock ORDER is part of the correctness, and a missed lock
// shows up as a total that drifts by a few units rather than as a crash.
type Bank = { locks: [mutex], bal: [long] };

def transfer(b: Bank, from: long, to: long, amt: long) -> void {
    if (from != to) {
        let lo = from;
        let hi = to;
        if (lo > hi) { lo = to; hi = from; };
        lock b.locks[lo] {
            lock b.locks[hi] {
                b.bal[from] = b.bal[from] - amt;
                b.bal[to] = b.bal[to] + amt;
            };
        };
    };
};

const ACCOUNTS = 12;
const THREADS = 8;
const MOVES = 2000;
let locks: [mutex] = [];
let bal: [long] = [];
for i in 0..ACCOUNTS { locks += mutex(); bal += 1000; };
let bank: Bank = {locks: locks, bal: bal};
let ts: [() -> long] = [];
for w in 0..THREADS {
    ts += spawn {
        let seed = w * 7919 + 1;
        let n = 0;
        while (n < MOVES) {
            seed = (seed * 1103515245 + 12345) % 2147483648;
            let from = seed % ACCOUNTS;
            seed = (seed * 1103515245 + 12345) % 2147483648;
            let to = seed % ACCOUNTS;
            transfer(bank, from, to, 1);
            n = n + 1;
        };
        MOVES
    };
};
let moves = 0;
foreach (t in ts) { moves = moves + join t; };
let total = 0;
for i in 0..ACCOUNTS { total = total + bank.bal[i]; };
print(moves);
print(total);
print(total == ACCOUNTS * 1000);
