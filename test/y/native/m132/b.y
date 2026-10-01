// Module for e132_duplicate_import_def.y (see a.y).
export { fb };

def helper() -> str { "b" };
def fb() -> str { helper() };
