// flags: --warnings=extra
// Level 1, relaxed: a dropped call warns only when NO call reads the def's
// value. `never` and `also` are only ever dropped, so each call is worth a
// word; `shared` is read in `reads_it`, so ignoring it in `drops_it` is a
// choice, not a mistake. `nothing` returns void, `inferred` has no written
// return type, and a builtin (len) is taken to return nothing.
def never() -> long { 7 };
def also() -> long { 8 };
def shared() -> long { 9 };
def reads_it() -> long { shared() + 1 };
def drops_it() -> long { shared(); 0 };
def nothing() -> void { puts("void\n") };
def inferred() { 3 };
def go() -> long {
    never();       // expect-warning: the value of 'never()' is not used
    also();        // expect-warning: the value of 'also()' is not used
    nothing();
    inferred();
    len("abcd");
    reads_it() + drops_it()
};
print(tostring(go()));
