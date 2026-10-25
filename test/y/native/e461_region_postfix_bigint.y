// expect-error: a reference made in this region escapes to 'kept'
let kept: bigint = 0n;
def post(n: bigint) -> bigint { n++ }
region {
    let value = 7n;
    heap { kept = post(value); }
}
print(kept);
