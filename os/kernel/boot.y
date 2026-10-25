// boot -- the Y-OS kernel program.
//
// qemu hands the kernel one Multiboot module: a YFS1 image (os/tools/mkfs.y).
// It is mounted where it lies -- the allocator already keeps off a module's
// pages -- so the files the shell makes and removes live in that memory until
// the machine stops. /bin/init (or, failing that, /sh) is loaded from it into a
// fresh address space and started; when it halts the machine (reboot(2)) or
// exits, so do we.
//
// yunix: os/kernel/sys.y is the system call table (y_os_sys and the lifecycle
// hooks override std/kernel.y's defaults); IRQ 0 is the 1 kHz clock (time.y)
// and IRQ 4 the console's receiver (tty.y).  `rows=N cols=N` on the kernel
// command line (qemu -append) set the terminal size.
import kernel;
import yfs;
import elf from "./elfload.y";
import sys from "./sys.y";
import time from "./time.y";
import tty from "./tty.y";
import kbd from "./kbd.y";
import display from "./display.y";
import vt from "./vt.y";
import kstat from "./kstat.y";

irq 0 def clock_irq() -> void {
    time.time_on_tick();
    vt.vt_tick();
    display.display_tick();
    if (display.display_ready() && vt.vt_frame_pending()) { vt.vt_flush_some(time.time_tick_cycles() / 4 + 1); };
};

irq 4 def serial_irq() -> void {
    kstat.kstat_irq_serial();
    tty.tty_on_rx();
};

irq 1 def keyboard_irq() -> void {
    kstat.kstat_irq_kbd();
    kbd.kbd_on_irq();
};

irq 12 def mouse_irq() -> void {
    kstat.kstat_irq_mouse();
    kbd.kbd_on_irq();
};

/** The number after `key` (e.g. "rows=") on the kernel command line, or 0. */
def cmdline_num(key: str) -> long {
    let at = kernel.mb_cmdline_addr();
    if (at == 0) { return 0; };
    let line = "";
    let n = kernel.str_len_at(at);
    let i = 0;
    while (i < n) { line += chr(kernel.peek8(at + i)); i = i + 1; };
    let k = line.index_of(key);
    if (k < 0) { return 0; };
    if (k > 0 && line[k - 1] != 32) { return 0; };
    let j = k + len(key);
    let v = 0;
    while (j < len(line) && line[j] >= 48 && line[j] <= 57) {
        v = v * 10 + line[j] - 48;
        j = j + 1;
    };
    v
};

kernel.init();
kernel.sched_init(kernel.vm_current(), kernel.kernel_stack_top());

if (kernel.mb_mod_count() < 1) {
    print("boot: no filesystem module (pass -initrd <os.fs>)\n");
    kernel.kexit(2);
};
let ok = yfs.yfs_init(kernel.mb_mod_start(0));
sys.sys_boot_init(cmdline_num("rows="), cmdline_num("cols="));
display.display_init(cmdline_num("fbw="), cmdline_num("fbh="));
let first = "init";
let ino = yfs.yfs_lookup_path("/bin/init");
if (ino < 0) {
    first = "sh";
    ino = yfs.yfs_lookup_path("/sh");
};
if (!ok || ino < 0) {
    print("boot: the module is not a YFS1 image with /bin/init or /sh in it\n");
    kernel.kexit(3);
};

let dir = kernel.vm_new_dir();
kernel.vm_switch(dir);
let entry = kernel.kexec_load(dir, ino);
if (entry == 0) {
    print("boot: /" + first + " is not a loadable program\n");
    kernel.kexit(4);
};
let sp = elf.elf_setup_stack([first]);
let kstack = kernel.pages_alloc_va(65536);
let ktop = kstack + 65536;
let frame = kernel.task_frame(ktop, entry, sp);
let pid = kernel.sched_add(dir, ktop, frame, first);
kernel.task_start(pid);
kernel.kexit(0);
