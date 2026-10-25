// expect-error: map value: expected long, got str
// map values are homogeneous
let m = {"a": 1};
m["b"] = "two";