// queue_test.y -- a stress test for the work-splitting pattern `perft.y` uses.
//
// WHY THIS IS A SEPARATE PROGRAM
//
// perft.y splits a search by handing root moves out of a mutex-guarded cursor
// and summing what the workers report.  That pattern has a failure mode a node
// count cannot show you: a worker that comes back round early finds the cursor
// past the end, takes nothing, and -- if it REPORTS by assignment -- wipes the
// subtree it already counted.  The total then comes out short, by an amount
// that depends on the wake-up order, and the property check in perft.y sees
// "threaded != single-threaded" without being able to say why.
//
// The first version of the pool did exactly that, and this test is what found
// it: 16 workers, 5 items, 3000 rounds -- 2715 wrong answers, every one of
// them SHORT, and not one of them announced.  With the report accumulated
// (`split[w] = split[w] + mine`) the same 3000 rounds are exact.
//
// So this is the same shape as the pool with the chess engine taken out: the
// items are worth 1 each, the queue is the same cursor, and the answer is
// compared with the number of items put in.  Run it after touching the pool:
//
//   ycc queue_test.y -o queue_test && ./queue_test
//
// It is deterministic in its VERDICT and deliberately racy in its schedule: the
// point is that the verdict does not move.

let jobs = sem(0);
let done = sem(0);
let vlk = mutex();

// The queue: QM holds the items, cursor claims, left counts down.
let QM: [long; 256] = [0; 256];
let cursor: long = 0;
let left: long = 0;
let split: [long; 16] = [0; 16];
let stopping: bool = false;
let workers: [() -> long] = [];
const NW: long = 16;
const ROUNDS: long = 3000;

// worker(w) -- one turn of the pool: take a token, drain the cursor, report.
def worker(w: long) -> long {
    let running = true;
    while (running) {
        wait(jobs);
        lock vlk {
            if (stopping) { running = false }
        };
        if (running) {
            let mine = 0;
            let go = true;
            while (go) {
                let m = 0;
                let claimed = false;
                lock vlk {
                    if (left > 0) {
                        m = QM[cursor];
                        cursor = cursor + 1;
                        left = left - 1;
                        claimed = true
                    }
                };
                if (claimed) {
                    mine += m
                } else {
                    go = false
                }
            };
            split[w] = split[w] + mine;
            post(done)
        }
    };
    0
}

def main() -> long {
    for w in 0..NW {
        workers += spawn { worker(w) }
    };
    let bad = 0;
    let round = 0;
    let maxseen = 0;
    while (round < ROUNDS) {
        // 5, 6 or 7 items, so the workers finish at different moments and some
        // of them come back for a second turn -- which is the whole point.
        let n = 5 + round % 3;
        let k = 0;
        while (k < n) {
            QM[k] = 1;
            k = k + 1
        };
        let i = 0;
        lock vlk {
            cursor = 0;
            left = n;
            i = 0;
            while (i < NW) {
                split[i] = 0;
                i = i + 1
            }
        };
        let w = 0;
        while (w < NW) {
            post(jobs);
            w = w + 1
        };
        w = 0;
        while (w < NW) {
            wait(done);
            w = w + 1
        };
        let total = 0;
        w = 0;
        while (w < NW) {
            total += split[w];
            if (split[w] > maxseen) { maxseen = split[w] };
            w = w + 1
        };
        if (total != n) { bad += 1 };
        round = round + 1
    };
    print("queue_test: ", tostring(ROUNDS), " rounds of 5..7 items over ", tostring(NW),
        " workers");
    print("  mismatches: ", tostring(bad), bad == 0 ? "" : "   <-- FAIL");
    print("  largest single share: ", tostring(maxseen),
        " (an uneven split is fine; a missing item is not)");
    // Stop the pool and wait for it, so nothing is left parked.
    lock vlk { stopping = true };
    let w = 0;
    while (w < NW) {
        post(jobs);
        w = w + 1
    };
    w = 0;
    while (w < NW) {
        join(workers[w]);
        w = w + 1
    };
    print("  pool stopped and joined");
    if (bad == 0) { 0 } else { 1 }
};

// main()'s return value is not the exit status -- exit() has to be called (the
// same note as in perft.y).
let code: long = main();
exit(code);