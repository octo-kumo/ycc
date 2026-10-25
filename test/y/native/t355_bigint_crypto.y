import crypto;

def main() -> long {
    print(crypto.is_prime(97n));
    print(crypto.is_prime(100n));
    print(crypto.bigint_gcd(48n, 18n));
    print(crypto.bigint_mod_pow(2n, 10n, 1000n));
    print(crypto.bigint_inv_mod(3n, 11n));
    let pb = crypto.random_prime_bytes(2);
    let p = crypto.bigint_from_bytes_be(pb);
    print(crypto.is_prime(p));
    print(pb.length == 2);
    0
};
exit(main());
