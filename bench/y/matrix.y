// bench/y/matrix.y — float arrays: dense matrix multiply and a dot-product
// loop over [float], the shape numeric code takes.
def mul(n: long) -> float {
    let a: [float] = [];
    let b: [float] = [];
    let c: [float] = [0.0; 122500];
    for i in 0..n * n { a += (i % 17) * 0.5; b += (i % 13) * 0.25; };
    for i in 0..n {
        for j in 0..n {
            let s = 0.0;
            for k in 0..n { s = s + a[i * n + k] * b[k * n + j]; };
            c[i * n + j] = s;
        };
    };
    let t = 0.0;
    for i in 0..n * n { t = t + c[i]; };
    t
};
print(mul(350));
