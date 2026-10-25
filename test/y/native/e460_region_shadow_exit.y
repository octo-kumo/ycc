// expect-error: 'retain' may keep a reference or grow memory outside the region
let kept: [long] = [];
def exit(code: long) -> void { }
def retain() -> long { kept = [7]; 0 }
region { exit(retain()); }
print(kept[0]);
