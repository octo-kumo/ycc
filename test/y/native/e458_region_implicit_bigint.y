// expect-error: a reference made in this region is returned out of it
def make() -> bigint {
    region { return 42; }
    0n
}
print(make());
