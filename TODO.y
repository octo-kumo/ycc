// this file contains language features i want to add

let a = true;
let b = a ? 1 : 3; // ternary conditional operator, equal to if (a) {1} else {3}

def printa() {
    print("a = ", a);
    // since last statement ends with ';' this function should return void
}

// void cant be assigned to a var, but should be usable in expressions
a ? printa() : none;

// tail recursion optimization
def factorial(n, acc = 1) {
    if (n <= 1) {
        return acc;
    }
    return factorial(n - 1, n * acc);
}

type A = {
    field1: long;
    field2: float;
};

type B = {
    bfield: long;
};

type C = A | B; // union type, can be either A or B

let c: C = {
    field1: 1,
    field2: 2.0
};

let c2: C = {
    bfield: 10
};

// whole block each arm must return same type or else the whole block returns void
// it is a type error if the match arms do not cover all possible cases
// a catch all arm is used to handle any cases not explicitly matched
match c {
    A { field1, field2 } => { // destructure A type to get its fields
        print("Matched A: ", field1, ", ", field2);
    },
    B b => { // bind the matched B instance to variable b
        print("Matched B: ", b.bfield);
    },
    _ => () // the () itself means void, also note how we can omit the curly here
};

// can be short as well, and can match anonymous patterns
match c {A a => 1, ({bfield: 10}) b => 2}



let text = "hello world";
// string slicing
print(text[2:5])
// get char
print(text[1]); // this will actually return a byte

let c = c'a'; // c-str denotes a character literal, c is of type byte


let buf:[byte] = [1, 2, 3, 4, 5];
let buf2:[byte] = [6, 7, 8];

buf[0:3] = buf2; // replace the first three elements of buf with the elements of buf2
buf[2:4] = buf2[0:2]; // replace the elements at index 2 and 3 of buf with the first two elements of buf2


let arr_of_arr:[[long]] = [[1, 2], [3, 4], [5, 6]];
let second_aarr: [[long]] = =[[7, 8], [9, 10]];

// [[long]] + [[long]] = [[long]]
let comb = arr_of_arr + second_aarr; // should be [[1, 2], [3, 4], [5, 6], [7, 8], [9, 10]]
// modifying the inner arrays of the original array should affect the combined array
arr_of_arr[0][0] = 100; // this should also change the first element of comb
// but modifying arr_of_arr itself should not affect comb
arr_of_arr += [[11, 12]]; // this should not change comb

// [[long]] + [long] = [[long]]
// even though this is also array + array, the second item is the item type of the first
let new_arr = arr_of_arr + [13, 14]; // should be [[1, 2], [3, 4], [5, 6], [13, 14]] (in the tests the changes earlier to arr_of_arr should be in different file)
let new_arr2 = [13, 14] + arr_of_arr; // should be [[13, 14], [1, 2], [3, 4], [5, 6]]

