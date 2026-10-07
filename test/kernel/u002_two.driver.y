// M2: two processes, two address spaces, two tasks -- started one after the
// other, with the switch happening on the way out of a syscall.  Task 0 is the
// kernel's own context, and it has no frame until something suspends it, which
// is why the scheduler only picks a task that has one.
import kernel;
import elf from "../../os/kernel/elfload.y";

kernel.init();
let phys = kernel.mb_mod_start(0);
let size = kernel.mb_mod_end(0) - phys;
print("it is an elf: " + tostring(elf.elf_ok(phys)));

kernel.sched_init(kernel.vm_current(), kernel.kernel_stack_top());

def spawn(name: str) -> long {
    let dir = kernel.vm_new_dir();
    kernel.vm_switch(dir);
    let entry = elf.elf_map(phys, size);
    let sp = elf.elf_setup_stack(name);
    let kstack = kernel.pages_alloc(65536);
    let ktop = kstack + 65536;
    let frame = kernel.task_frame(ktop, entry, sp);
    kernel.sched_add(dir, ktop, frame, name)
};

let a = spawn("A");
let b = spawn("B");
print("tasks: " + tostring(kernel.task_count()));
print("pids: " + tostring(kernel.task_pid(a)) + " and " + tostring(kernel.task_pid(b)));
puts("starting A\n");
kernel.task_start(a);
puts("back in the kernel\n");
kernel.kexit(9);
