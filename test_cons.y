// Test 1: :: cons operator - should crash in VM due to missing break
let arr = [1, 2, 3];
let result = 0 :: arr;
print(result);
