// M3's first piece: two user processes talking over ports.  The client's
// argv carries the server's pid -- which is the port -- because there is no
// name service yet.
import kernel;

kernel.init();
let phys = kernel.mb_mod_start(0);
let size = kernel.mb_mod_end(0) - phys;
kernel.sched_init(kernel.vm_current(), kernel.kernel_stack_top());

def spawn(args: [str]) -> long {
    let dir = kernel.vm_new_dir();
    kernel.vm_switch(dir);
    let entry = elf_map(phys, size);
    let sp = elf_setup_stack(args);
    let kstack = kernel.pages_alloc_va(65536);
    let ktop = kstack + 65536;
    let frame = kernel.task_frame(ktop, entry, sp);
    kernel.sched_add(dir, ktop, frame, args[0])
};

let s = spawn(["prog", "srv"]);
let c = spawn(["prog", "cli", tostring(kernel.task_pid(s))]);
print("ports: " + tostring(kernel.task_pid(s)) + " and " + tostring(kernel.task_pid(c)));
puts("starting the server\n");
kernel.task_start(s);
kernel.kexit(9);
