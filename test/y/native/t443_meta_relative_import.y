// A generator import belongs to its module's directory, not the root's.
import generated from "./meta_nested/generated.y";
print(generated.imported_value);
