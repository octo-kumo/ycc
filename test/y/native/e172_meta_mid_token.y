// expect-error: 2:11: error: a meta block cannot sit between two tokens of an expression: a block generates text, and there is no position for the call between 'a' and '('
def helper#{x++}#() -> long { 7 };
print(helper());
