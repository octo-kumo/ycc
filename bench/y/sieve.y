// bench/y/sieve.y — packed [byte] arrays and integer bit operations: a prime
// sieve, a popcount, and a xorshift generator (shifts, masks, xor, immediates).
def sieve(n: long) -> long {
    let s: [byte] = [1; 2000000];
    let c = 0;
    for i in 2..n {
        if (s[i] == 1) {
            c++;
            let j = i * i;
            while (j < n) { s[j] = 0; j = j + i; };
        };
    };
    c
};
def popcount(x: long) -> long {
    let v = x;
    let c = 0;
    while (v != 0) { c = c + (v & 1); v = v >>> 1; };
    c
};
def xorshift(n: long) -> long {
    let x = 88172645463325252;
    let acc = 0;
    for i in 0..n {
        x = x ^ (x << 13);
        x = x ^ (x >>> 7);
        x = x ^ (x << 17);
        acc = acc + (x & 255);
    };
    acc
};
print(sieve(2000000) + popcount(xorshift(30000000)));
