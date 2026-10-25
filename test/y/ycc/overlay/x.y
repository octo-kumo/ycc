// A base whose export statement spans lines: the overlay adds C to it.
const A = 1;
const B = 2;
def f() -> str { "base" };
export {
    A,
    B,
    f
};
