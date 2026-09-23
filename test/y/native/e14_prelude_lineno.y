// expect-error: 7:7: error: undefined variable
// Error positions must refer to THIS file, not to the text after the
// prelude is spliced in front of it. Mentioning readline() pulls the
// prelude in, which used to shift every position below it.
let line = readline();
let ok = line == null;
print(nope);
