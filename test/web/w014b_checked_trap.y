// W4/S8: --web-checked turns a byte address that is not a wasm32 address
// into trap(11), status 139.  A pointer moved past 2^32 is such an address;
// the unchecked build would wrap it and read whatever is there.
let a = [1, 2, 3];
let p = &a[0];
let far = p + 4294967296;
print("before\n");
print(*far, "\n");
print("not reached\n");
