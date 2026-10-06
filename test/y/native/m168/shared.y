// One file, imported twice by two spellings: the same module reached
// through "./shared.y" and through "./sub/../shared.y". norm_path folds "/./"
// but used to leave "/../" alone, so the two spellings were two keys, the
// import splicer's seen check missed, and this module was spliced twice --
// every name in it reported as a duplicate definition against itself.
def value() -> long { 42 };
export { value };
