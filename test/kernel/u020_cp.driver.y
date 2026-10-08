// Two files in the image: the program itself (/prog) and a text file (/msg =
// "hi from yfs\n").  BOTH get their direct slots filled in a loop -- the bug that
// made the first attempt at this fault was a program longer than one block whose
// second block was never recorded, so the ELF was loaded truncated.
import kernel;
import elf from "../../os/kernel/elfload.y";

def p8(addr: long, v: long) -> void { kernel.poke_va8(addr, v & 255); };

def p32(addr: long, v: long) -> void {
    p8(addr, v & 255);
    p8(addr + 1, (v >> 8) & 255);
    p8(addr + 2, (v >> 16) & 255);
    p8(addr + 3, (v >> 24) & 255);
};

def p16(addr: long, v: long) -> void {
    p8(addr, v & 255);
    p8(addr + 1, (v >> 8) & 255);
};

const BS = 4096;

kernel.init();
let mphys = kernel.mb_mod_start(0);
let msize = kernel.mb_mod_end(0) - mphys;
kernel.sched_init(kernel.vm_current(), kernel.kernel_stack_top());

let msg = "hi from yfs\n";
let nprog = (msize + BS - 1) / BS;
let data_start = 5;
let prog_at = data_start + 1;
let msg_at = prog_at + nprog;
let npages = msg_at + 1;
let img = 0;
let i = 0;
while (i < npages) {
    let p = kernel.page_alloc();
    if (i == 0) { img = p; };
    i = i + 1;
};
p8(img, 89); p8(img + 1, 70); p8(img + 2, 83); p8(img + 3, 49);
p32(img + 4, 1);
p32(img + 8, BS);
p32(img + 12, npages);
p32(img + 16, 256);
p32(img + 20, 1);
p32(img + 24, data_start);
p32(img + BS + 64, 2);
p32(img + BS + 68, 2);
p32(img + BS + 72, data_start);
p16(img + data_start * BS, 4);
p16(img + data_start * BS + 2, 1);
p32(img + data_start * BS + 4, 2);
p8(img + data_start * BS + 8, 112); p8(img + data_start * BS + 9, 114); p8(img + data_start * BS + 10, 111); p8(img + data_start * BS + 11, 103);
p16(img + data_start * BS + 12, 3);
p16(img + data_start * BS + 14, 1);
p32(img + data_start * BS + 16, 3);
p8(img + data_start * BS + 20, 109); p8(img + data_start * BS + 21, 115); p8(img + data_start * BS + 22, 103);
p32(img + BS + 128, 1);
p32(img + BS + 132, msize);
let dib = 0;
while (dib < nprog) { p32(img + BS + 136 + dib * 4, prog_at + dib); dib = dib + 1; };
p32(img + BS + 192, 1);
p32(img + BS + 196, len(msg));
p32(img + BS + 200, msg_at);
let k = 0;
while (k < msize) { p8(img + prog_at * BS + k, kernel.peek8(mphys + k)); k = k + 1; };
let m = 0;
while (m < len(msg)) { p8(img + msg_at * BS + m, msg[m]); m = m + 1; };
let ok = yfs_init(img);
print("fs ok=" + tostring(ok) + " msg=" + tostring(yfs_lookup_path("/msg")) + "\n");
let dir = kernel.vm_new_dir();
kernel.vm_switch(dir);
let entry = elf.elf_map(img + prog_at * BS, msize);
let sp = elf.elf_setup_stack(["cp"]);
let kstack = kernel.pages_alloc_va(65536);
let ktop = kstack + 65536;
let frame = kernel.task_frame(ktop, entry, sp);
let pid = kernel.sched_add(dir, ktop, frame, "cat");
kernel.task_start(pid);
kernel.kexit(9);
