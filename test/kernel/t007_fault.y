// A CPU exception, reported by the generated stub through the Y handler
// std/kernel.y defines: vector 14 is #PF, and the error code says why.
import kernel;

kernel.init();
puts("mapping\n");
let dir = kernel.vm_current();
let p = kernel.page_alloc();
print(kernel.vm_map(dir, 1073741824, p, kernel.PTE_W));
puts("mapped\n");
print(kernel.vm_translate(dir, 1073741824) == p);
puts("faulting\n");
// A VIRTUAL address that was never mapped: poke_va64 reads through the
// current address space, poke64 through the direct map (physical).
kernel.poke_va64(1202590848, 1);
puts("never printed\n");
kernel.halt();
