// Physical memory and virtual memory, from Y.
//
// Nothing here is assembly: the Multiboot info is read with pointer
// arithmetic on one anchor (`std/kernel.y`'s peek/poke), page tables are
// walked with the same two primitives, and the only machine-level step is
// `mov %cr3` where an address space switches.  The labels matter -- this is
// the case that says which part of a page-table walk is wrong when it breaks.
import kernel;

kernel.init();

let mb = kernel.mb_present();
print("multiboot info present: " + tostring(mb));
print("ram above 1MB (KB): " + tostring(kernel.mb_mem_upper_kb()) + " usable: " + tostring(kernel.mb_mem_upper_kb() > 8000));
print("available regions: " + tostring(kernel.mb_region_count()));
print("free bytes after the kernel: " + tostring(kernel.phys_free_bytes() > 1048576));

// A fresh physical page, mapped where nothing is mapped yet.
let p = kernel.page_alloc();
print("page_alloc: " + tostring(p != 0));
let dir = kernel.vm_current();
print("1GB is unmapped to start: " + tostring(kernel.vm_translate(dir, 1073741824) == 0));
print("vm_map: " + tostring(kernel.vm_map(dir, 1073741824, p, kernel.PTE_W)));
print("translate gives the page back: " + tostring(kernel.vm_translate(dir, 1073741824) == p));

// Through the virtual address, back through the physical one: one memory.
kernel.poke_va64(1073741824, 305419896);
print("write VA, read PA: " + tostring(kernel.peek64(p) == 305419896));
kernel.poke64(p, 42);
print("write PA, read VA: " + tostring(kernel.peek_va64(1073741824) == 42));
print("the rest of the page is untouched: " + tostring(kernel.peek64(p + 8) == 0));

// Five more pages, each written through its virtual address and read back.
print("vm_map_range: " + tostring(kernel.vm_map_range(dir, 1073745920, kernel.pages_alloc(16384), 4, kernel.PTE_W) == 4));
let i = 0;
while (i < 4) {
    kernel.poke_va64(1073745920 + i * 4096, i + 1);
    i = i + 1;
};
i = 0;
let sum = 0;
while (i < 4) {
    sum = sum + kernel.peek_va64(1073745920 + i * 4096);
    i = i + 1;
};
print("sum over the four pages: " + tostring(sum));

// Unmapping takes the translation away, and a fresh directory starts with
// the kernel's own 1 GB still reachable.
kernel.vm_unmap(dir, 1073741824);
print("after vm_unmap: " + tostring(kernel.vm_translate(dir, 1073741824) == 0));
let dir2 = kernel.vm_new_dir();
print("new dir shares the kernel's map: " + tostring(kernel.vm_translate(dir2, 1048576) == 1048576));
print("new dir has no user mappings: " + tostring(kernel.vm_translate(dir2, 1073745920) == 0));
kernel.halt();
