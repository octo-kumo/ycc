// Test 8: operator precedence - 2 + 3 * 4 should be 14
// With right-associative flat parsing: 2 + (3 * 4) = 14 (accidentally correct)
// But 2 * 3 + 4 should be 10, parses as 2 * (3 + 4) = 14 (WRONG)
let x = 2 * 3 + 4;
print(x);
