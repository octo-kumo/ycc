// A pattern type must be a record or a primitive: an alias to an array is
// neither, and the error names what was written.
// expect-error: 7:12: error: match pattern type [long] is not a record or primitive type
type A = [long];
def main() -> long {
    let a: A = [1];
    if let A x = a { print(x); } else { print(0); };
    0
}
exit(main());
