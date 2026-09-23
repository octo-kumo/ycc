// block expressions and immediately-invoked function literals
let computed = {
    let tmp = 10;
    tmp = tmp * 2;
    tmp + 1
};
print(computed);

// a block is an expression anywhere an expression is allowed
print({ let x = 3; x * x });

// blocks nest and get their own scope
let outer = 1;
let nested = {
    let outer = 100;
    { let outer = 5; outer + 1 }
};
print(outer);
print(nested);

// immediately-invoked function literal
print((def(x: long) -> long { x + 1 })(41));

// IIFE with captures
let base = 1000;
print((def(x: long) -> long { x + base })(7));

// calling a function pulled out of an array
let fs = [def(x: long) -> long { x * 2 }, def(x: long) -> long { x * 3 }];
let f0 = fs[0];
let f1 = fs[1];
print(f0(21));
print(f1(14));

// a block used purely for its effect
let t = 0;
{
    t = 7;
};
print(t);
