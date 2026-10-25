// Module for e132_duplicate_import_def.y: b.y defines helper again, the
// program twice.
export { fa, twice };

def helper() -> str { "a" };
def fa() -> str { helper() };
def twice(x: long) -> long { x + x };
