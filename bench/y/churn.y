// bench/y/churn.y — allocation churn with a live set: short-lived strings and
// arrays discarded each round while a window of them stays reachable.
def churn(n: long) -> long {
    let live: [[long]] = [];
    let words: [str] = [];
    let acc = 0;
    for i in 0..n {
        let a = [i, i + 1, i + 2, i + 3];
        let w = "w" + tostring(i % 97) + "-" + tostring(i);
        if (i % 16 == 0) { live += a; words += w; };
        if (len(live) > 400) { live = live[200:]; words = words[200:]; };
        acc = acc + a[i % 4] + len(w);
    };
    acc + len(live) + len(words)
};
print(churn(500000));
