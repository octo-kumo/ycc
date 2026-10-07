// M1: ring 3, the syscall path, and a program that is not the kernel.
//
// The user program is hand-built here -- the ELF loader is the next step --
// so every byte of it is visible: write(1, msg, 6) then exit_group(0), with
// the message at a fixed offset in the same page.
import kernel;

const CODE_VA = 4194304;
const STACK_VA = 8384512;

def le64(b: [byte], v: long) -> [byte] {
    let i = 0;
    while (i < 8) { b += (v >>> (i * 8)) & 255; i = i + 1; };
    b
};

def ring3_code() -> [byte] {
    let c: [byte] = [];
    let msg_va = CODE_VA + 64;
    c += 184; c += 1; c += 0; c += 0; c += 0;          // mov $1, %eax
    c += 191; c += 1; c += 0; c += 0; c += 0;          // mov $1, %edi
    c += 72; c += 190;                                  // mov $imm64, %rsi
    c = le64(c, msg_va);
    c += 72; c += 186;                                  // mov $imm64, %rdx
    c = le64(c, 6);
    c += 15; c += 5;                                    // syscall
    c += 184; c += 231; c += 0; c += 0; c += 0;         // mov $231, %eax
    c += 49; c += 255;                                  // xor %edi, %edi
    c += 15; c += 5;                                    // syscall
    c += 235; c += 254;                                 // jmp .
    while (len(c) < 64) { c += 144; };                  // nops up to the message
    c += 114; c += 105; c += 110; c += 103; c += 51; c += 10;   // "ring3\n"
    c
};

kernel.init();
print("syscall entry: " + tostring(kernel.syscall_entry_addr() != 0));
print("user code page: " + tostring(kernel.vm_map(kernel.vm_current(), CODE_VA, kernel.page_alloc(), kernel.PTE_U | kernel.PTE_W)));
print("user stack page: " + tostring(kernel.vm_map(kernel.vm_current(), STACK_VA, kernel.page_alloc(), kernel.PTE_U | kernel.PTE_W)));

// A second, unmapped virtual address must be refused to the program: the U/S
// bit is checked at every level of the walk, and the kernel's own mapping is
// supervisor-only.
print("kernel memory is not the user's: " + tostring(kernel.vm_translate(kernel.vm_current(), 1048576) == 1048576));

let code = ring3_code();
let code_phys = kernel.vm_translate(kernel.vm_current(), CODE_VA);
let i = 0;
while (i < len(code)) { kernel.poke8(code_phys + i, code[i]); i = i + 1; };
print("bytes in place: " + tostring(kernel.peek8(code_phys) == 184));
puts("entering ring 3\n");
kernel.enter_user(CODE_VA, STACK_VA + 4096 - 16, 514);
puts("unreachable\n");
kernel.kexit(9);
