// expect-error: 6:24: error: cannot take the address of function 'value$31'
// expect-error: 8:27: error: cannot take the address of a whole array (use &array[i] for elements)
// expect-error: 10:26: error: '&' needs a plain variable (only locals/params have addresses)
// expect-error: 11:20: error: '&' needs a plain variable (only locals/params have addresses)
def value() -> long { 1 };
let function_address = &value;
let array = [1];
let whole_array_address = &array;
let number = 1;
let expression_address = &(number + 1);
let call_address = &value();
