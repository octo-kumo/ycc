// expect-error: '+=' appended elements: expected [long], got str
// Arrays are homogeneous: on a [[long]], `+=` takes a row ([long], pushed
// whole) or rows ([[long]], their elements appended) -- a [str] is neither.
let rows = [[1], [2]];
rows += ["x"];
print(len(rows));
