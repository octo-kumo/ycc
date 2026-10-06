// The fix the diagnostic now names, and the forms that were always fine.
// `def f() { return; }` infers `void` from a tail that is nothing, so the
// bare `return;` agrees with it; write the type and it agrees with that.
def nothing() { return; };
print("nothing ", nothing() == ());

// the same with the type written out
def also_nothing() -> void { return; };
print("also ", also_nothing() == ());

// a void tail: a call statement is a statement, so it infers void
def prints() { print(""); };
prints();

// and the inferred non-void case, where the value comes back
def valued() { if (true) { return 1; }; 0 };
print("valued ", valued());

// a `return` carrying a value, next to a tail of the same type
def written() -> long { if (true) { return 1; }; 0 };
print("written ", written());

def written_bool() -> bool { if (true) { return true; }; false };
print("bool ", written_bool());