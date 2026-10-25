// A malformed f-string field's spec argument is not a spec: the parser
// plants an err node there (`f"{a b}"` lexes to `#fmt(a b , "")`, and the
// argument list stops at the error). types.y's typeof_fmt read that node as
// a Leaf -- a *checked* union cast -- and so died with "a union value cast
// to a member it does not hold", printing no diagnostics at all and leaving
// a core dump, where cycc (whose twin has no tag to check and simply reads
// a field that is not there) reported all three errors below. The same cast
// sat in native.y's gen_fmt, one call away; leaf_of now answers none for an
// err node and both sides stop.
// expect-error: 13:3: error: cannot call long (not a function)
// expect-error: 13:6: error: undefined variable 'a'
// expect-error: 13:8: error: unexpected 'b' (expected ',' or ')')
1 f"{a b}";