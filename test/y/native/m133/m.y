// Module for e133_import_error_positions.y: an export list over several
// lines (dropped from the splice) above a type error.
export {
    six,
    seven
};

def six() -> long { 6 };
def seven() -> long { let s: str = 7; 7 };
