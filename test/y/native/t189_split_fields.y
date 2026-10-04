// split: the rule the manual states, and the reason it is that rule (m9).
//
// A trailing empty piece is dropped -- exactly one -- and an empty string
// gives an empty array. That is Python's splitlines rule rather than its
// split, and it is what makes split(s, "\n") and s.lines() the same answer
// for every input; the shapes below check that they do agree.
print("a,b".split(","));
print("a,".split(","));      // the trailing empty is dropped
print(",a".split(","));      // a leading one is not
print("a,,b".split(","));    // an interior one is not
print("a,,".split(","));     // exactly one is dropped, not all of them
print(",,a".split(","));
print("".split(","));        // no pieces at all
print("abc".split(","));     // no separator, one piece
print("a".split(",,"));
print(",".split(",,"));     // the piece is the separator itself
print("".split(""));         // an empty separator gives nothing

// The same separator as a newline, against lines(): they agree, every shape.
print("a\nb".split("\n"), " ", "a\nb".lines());
print("a\n\nb".split("\n"), " ", "a\n\nb".lines());
print("a\n".split("\n"), " ", "a\n".lines());
print("\na".split("\n"), " ", "\na".lines());
print("\n".split("\n"), " ", "\n".lines());
print("".split("\n"), " ", "".lines());
// lines() also drops the CR of a CRLF pair, so the two agree on the pieces
// except for that: lengths make it visible where printing cannot.
let crlf_split = "a\r\nb\r\n".split("\n");
let crlf_lines = "a\r\nb\r\n".lines();
print([len(crlf_split), crlf_split[0].length, len(crlf_lines), crlf_lines[0].length]);

// The consequence worth knowing: joining the pieces back reproduces the
// string exactly unless it ends in the separator.
print(join("a,b,c".split(","), ","));
print(join("a,b,".split(","), ","));      // the trailing separator is lost
print(join("a,b,".split(",") + [","], ","));   // so put it back by hand