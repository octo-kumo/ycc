// flags: --warnings=all
// The value of `thread` is read in use_val, so dropping it in drop_it is a
// choice, not a mistake: the level-1 rule says nothing.
def thread(st: long, n: long) -> long { st + n };
def use_val(n: long) -> long { if (thread(1, n) > 0) { 1 } else { 0 } };
def drop_it(n: long) -> long { thread(1, n); 0 };
def main() -> long { print(use_val(1)); print(drop_it(1)); 0 };
exit(main());
