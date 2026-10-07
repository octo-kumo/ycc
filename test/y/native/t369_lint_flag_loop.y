// flags: -W 2
def f(n: long) -> long {
    let i = 0;
    let rdone = false; // expect-warning: 'rdone' only stops this loop; write 'while (true)' and 'break' where it is set
    while (!rdone) {
        i++;
        if (i > n) { rdone = true; };
    };
    i
};
def main() -> long { print(f(3)); 0 };
exit(main());
