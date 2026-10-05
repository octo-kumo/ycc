// One module reached by two spellings is one module. `shared.y` is imported
// here as "./m168/shared.y" and, through `sub/other.y`, as
// "./m168/sub/../shared.y": norm_path folds "/./" but used to leave "/../"
// alone, so the two spellings were two keys, the import splicer's seen check
// missed, and the module was spliced twice -- every name in it reported as a
// duplicate definition against itself (38 such errors for std/fs.y alone,
// when the second spelling was the one with the ".." in it).
//
// This is the shape that bites a real tool: `import fs;` by name and a
// sibling by a relative path that steps out and back into src/y/. It needs
// no std module to show, because the fold is in the path key itself.
import direct from "./m168/shared.y";
import via from "./m168/sub/other.y";

// both names are the same binding's module, reached two ways
print(direct.value() + via.doubled());