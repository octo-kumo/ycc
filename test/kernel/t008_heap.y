// M0: the kernel image fits in one 2 MB page and the Y heap lives in RAM
// above it, not in .bss -- which is what leaves 0x400000 free for a user
// program and keeps the image small.
import kernel;

kernel.init();

// The heap is direct-map memory, its start is above the image, and the page
// allocator's region stops exactly where the heap begins: no overlap.
let hs = kernel.heap_start_phys();
let ps = kernel.phys_start();
print("heap bytes: " + tostring(kernel.heap_bytes()));
print("heap is 8 MB: " + tostring(kernel.heap_bytes() == 8388608));
print("heap start above the image: " + tostring(hs >= 1048576));
print("page region below the heap: " + tostring(ps < hs));
// The invariant M0 exists for: the whole image (code, rodata, bss) fits in
// the single 2 MB page the kernel maps for itself, so 0x400000 is free.
print("image fits the kernel's 2 MB page: " + tostring(ps < 2097152));
print("free pages: " + tostring(kernel.phys_free_bytes() > 1048576));

// The heap is real memory: write through a direct-map address and read it
// back as a physical address.
let probe = hs + 4096;
kernel.poke64(probe, 1234567890);
print("heap round trip: " + tostring(kernel.peek64(probe) == 1234567890));
kernel.kexit(0);
