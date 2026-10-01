// Module for t134_import_namespace.y: replaces a std def, and has a
// global named like one of the program's.
export { eof_state, get, lf };

let count = 1;
def clear_eof() -> long { 7 };
def eof_state() -> long { clear_eof() };
def get() -> long { count };
def lf(x: long) -> long { x + 1 };
