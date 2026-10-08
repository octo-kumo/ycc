// boot -- the Y-OS kernel program.
//
// qemu hands the kernel one Multiboot module: a YFS1 image (os/tools/mkfs.y).
// It is mounted where it lies -- the allocator already keeps off a module's
// pages -- so the files the shell makes and removes live in that memory until
// the machine stops. /sh is loaded from it into a fresh address space and
// started; when the shell halts the machine (reboot(2)) or exits, so do we.
import kernel;
import yfs;
import elf from "./elfload.y";

kernel.init();
kernel.sched_init(kernel.vm_current(), kernel.kernel_stack_top());

if (kernel.mb_mod_count() < 1) {
    print("boot: no filesystem module (pass -initrd <os.fs>)\n");
    kernel.kexit(2);
};
let ok = yfs.yfs_init(kernel.mb_mod_start(0));
let ino = yfs.yfs_lookup_path("/sh");
if (!ok || ino < 0) {
    print("boot: the module is not a YFS1 image with /sh in it\n");
    kernel.kexit(3);
};

let dir = kernel.vm_new_dir();
kernel.vm_switch(dir);
let entry = kernel.kexec_load(dir, ino);
if (entry == 0) {
    print("boot: /sh is not a loadable program\n");
    kernel.kexit(4);
};
let sp = elf.elf_setup_stack(["sh"]);
let kstack = kernel.pages_alloc_va(65536);
let ktop = kstack + 65536;
let frame = kernel.task_frame(ktop, entry, sp);
let pid = kernel.sched_add(dir, ktop, frame, "sh");
kernel.task_start(pid);
kernel.kexit(0);
