// expect-error: 3:15: error: expected a type in a type, got ')'
// expect-error: 4:32: error: expected ':' in conditional expression, got '}'
let bad_type: ) = 1;
{ let missing_colon = true ? 1 }
