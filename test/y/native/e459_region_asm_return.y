// expect-error: a reference made in this region is returned out of it
ndef zeroes(n: long) -> [byte] = "y_bytes_zero";
def make() -> [byte] {
    region { return zeroes(8); }
    []
}
print(make().length);
