// The driver every `u*` case shares: the module qemu was handed with -initrd
// is a ycc-compiled Linux program, and this kernel loads it and leaves for
// ring 3.  The program is whatever the case's `.user.y` compiled to.
import kernel;

kernel.init();
let n = kernel.mb_mod_count();
if (n == 0) { puts("no initrd\n"); kernel.kexit(3); };
let phys = kernel.mb_mod_start(0);
let size = kernel.mb_mod_end(0) - phys;
print("module bytes: " + tostring(size > 0));
print("it is an elf: " + tostring(elf_ok(phys)));
puts("entering ring 3\n");
elf_load(phys, size, ["prog"]);
puts("load failed\n");
kernel.kexit(5);
