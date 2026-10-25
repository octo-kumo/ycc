// W4/S6: the flag model, as a Y program can see it.  Every comparison here
// runs through the flag state: the cmp/add/inc producers record it, and a
// consumer either folds the comparison into one i32 test or calls $cond when
// the producer is in another case (a loop's back edge, an if-join).  A wrong
// flag shows up as a different word in the output.
import math;

// inc/dec in a loop: their CF is not read, so nothing records it; the
// comparison at the top is the producer for the branch below it.
def count_up(n: long) -> long {
    let i = 0;
    let hits = 0;
    while (i < n) {
        i++;
        if (i % 7 == 0) { hits = hits + 1; };
    };
    hits
};

// a shift whose count is zero at run time must leave the flags alone; the
// comparison after it is the one that decides the branch
def shift_zero(x: long, z: long) -> long {
    let y = x << z;
    let w = x >> z;
    if (y != x) { return -1; };
    if (w != x) { return -2; };
    x + y + w
};

// a shift by 64 moves every bit out
def shift_64(x: long) -> long { x >> 64 };

// comparisons on both sides of a call and of a join label
def pick(a: long, b: long) -> long {
    if (a < b) { a } else { b }
};

print(count_up(1000), "\n");
print(shift_zero(12345, 0), " ", shift_zero(-7, 0), "\n");
print(shift_64(12345), " ", shift_64(-12345), "\n");
print(pick(3, 9), " ", pick(9, 3), "\n");
let ok = 0;
let i = 0;
while (i < 100) {
    if (pick(i, 50) == i) { ok = ok + 1; };
    if (i < 50) { ok = ok + 1; };
    i++;
};
print(ok, "\n");
// ucomisd's ordering through comparisons: NaN is unordered, infinity is not
let nan = 0.0 / 0.0;
let inf = 1.0 / 0.0;
print(nan < 1.0, " ", nan > 1.0, " ", nan == nan, " ", nan != nan, "\n");
print(inf > 1.0e308, " ", -inf < 0.0, " ", inf == inf, "\n");
print(math.fbits(nan) == -2251799813685248, "\n");
