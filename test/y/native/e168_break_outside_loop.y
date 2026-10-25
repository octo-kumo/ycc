// `break` leaves a loop. At the top level of a function there is none, so it
// is a compile-time error rather than a jump to whatever label happened to be
// nearest -- which would land in an unrelated body. Both words are checked, and
// the statement after a jump is parsed normally (`break;` then `1` reports only
// the jump, not a complaint about the `;`).
// expect-error: 9:5: error: 'break' outside of a loop
// expect-error: 10:5: error: 'continue' outside of a loop
def f() -> long {
    break;
    continue;
    1
}
print(f());
