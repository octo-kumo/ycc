def make_adder(x: long) -> (long) -> long {
    def adder(y: long) -> long {
        x + y
    };
    adder
};
let add5 = make_adder(5);
let result = add5(10);
print(result);
