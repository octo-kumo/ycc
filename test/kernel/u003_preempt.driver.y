// M2: preemption.  The timer handler only marks the tick -- the switch happens
// on the way out of the interrupt, and only for a user frame -- so a program
// that never traps still loses the CPU.
import kernel;
import elf from "../../os/kernel/elfload.y";

irq 0 def timer_tick() -> void {
    kernel.sched_tick();
};

kernel.init();
let phys = kernel.mb_mod_start(0);
let size = kernel.mb_mod_end(0) - phys;
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

let a = spawn("spin");
let b = spawn("print");
print("tasks: " + tostring(kernel.task_count()));
puts("starting the spinner: the printer should run first\n");
kernel.task_start(a);
kernel.kexit(9);
