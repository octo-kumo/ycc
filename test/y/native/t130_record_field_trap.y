// A `{k: str}` parameter accepts any record, so a field read through it is
// looked up at run time; a missing field traps, naming the field.
def missing_field(r: { k: str }) { r.missing };
print("before");
missing_field({ k: "x" });
print("after");
