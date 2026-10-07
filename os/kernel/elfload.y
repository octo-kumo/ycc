// The ELF64 loader: what turns a ycc-compiled Linux binary into a running
// program.  The format is the one src/y/elf.y writes -- ET_EXEC, two
// PT_LOADs, no interpreter, no relocations -- and it is read straight out of
// physical memory (Multiboot's module, or a file the FS server maps), because
// the kernel is looking at a byte string, not at a file.
//
// Every reference inside such an image is rip-relative or a length
// difference (src/y/NATIVE.md), so the loader honours p_vaddr and does not
// have to relocate: the image is linked at 0x400000, which is why the kernel
// maps itself into one 2 MB page and keeps the rest of the low half free.
import kernel;

const ELF_MAGIC = 1179403647;         // 0x464C457F, little-endian "\x7fELF"
const PT_LOAD = 1;

// Where the program's stack goes, and how much of it: below the mmap region,
// so neither can grow into the other in this milestone's single address space.
const STACK_BASE = 100663296;         // 0x6000000
const STACK_BYTES = 65536;

def elf_ok(phys: long) -> bool {
    kernel.peek32(phys) == ELF_MAGIC
};

// Map `want` bytes of the module's image at `va`, copy `filesz` bytes of it
// from `phys + off`, and zero the rest.  The copy goes through the kernel's
// virtual accessors: the mapping belongs to the program, and the kernel is
// simply the one that made it.
def elf_segment(phys: long, off: long, va: long, filesz: long, memsz: long, flags: long) -> bool {
    let pte = kernel.PTE_U | kernel.PTE_W;
    let dir = kernel.vm_current();
    let page = 0;
    while (page < memsz) {
        let got = kernel.page_alloc();
        if (got == 0) { return false; };
        if (!kernel.vm_map(dir, va + page, got, pte)) { return false; };
        page = page + 4096;
    };
    let i = 0;
    while (i < filesz) {
        kernel.poke_va8(va + i, kernel.peek8(phys + off + i));
        i = i + 1;
    };
    while (i < memsz) {
        kernel.poke_va8(va + i, 0);
        i = i + 1;
    };
    flags == 0 || true
};

// The program's first stack frame: [argc][argv0]...[NULL], a NULL envp, and
// the argument strings above it -- exactly the layout the emitted `_start`
// reads (argc from (%rsp), argv from %rsp+8).
def elf_stack(top: long, args: [str]) -> long {
    let sp = top;
    let ptrs: [long] = [];
    let i = 0;
    while (i < len(args)) {
        let s: str = args[i];
        let n = len(s);
        sp = sp - n - 1;
        let j = 0;
        while (j < n) {
            kernel.poke_va8(sp + j, byte_at(s, j));
            j = j + 1;
        };
        kernel.poke_va8(sp + n, 0);
        ptrs += sp;
        i = i + 1;
    };
    // The word writes need 8-byte alignment: poke_va64 moves in whole 8-byte
    // words (`*(p + k)` is p + 8k), so an unaligned store lands at the NEXT
    // multiple of 8 and the word it was meant for keeps whatever the page
    // held.
    sp = sp - (sp & 7);
    sp = sp - 8; kernel.poke_va64(sp, 0);                 // envp = NULL
    sp = sp - 8; kernel.poke_va64(sp, 0);                 // argv[argc] = NULL
    let k = len(ptrs) - 1;
    while (k >= 0) {
        sp = sp - 8;
        kernel.poke_va64(sp, ptrs[k]);
        k = k - 1;
    };
    sp = sp - 8; kernel.poke_va64(sp, len(ptrs));         // argc
    sp
};

// Map the image into the CURRENT address space and answer its entry point.
// The caller has already switched to the address space this program belongs
// to: the kernel's own mappings are in every one of them, and the pages below
// (mmap, the stack) are what make this one the program's.
def elf_map(phys: long, size: long) -> long {
    if (!elf_ok(phys) || size <= 0) { return 0; };
    let entry = kernel.peek64(phys + 24);
    let phoff = kernel.peek64(phys + 32);
    let phentsize = kernel.peek32(phys + 54);
    let phnum = kernel.peek32(phys + 56);
    let i = 0;
    while (i < phnum) {
        let ph = phys + phoff + i * phentsize;
        if (kernel.peek32(ph) == PT_LOAD) {
            let off = kernel.peek64(ph + 8);
            let va = kernel.peek64(ph + 16);
            let filesz = kernel.peek64(ph + 32);
            let memsz = kernel.peek64(ph + 40);
            if (!elf_segment(phys, off, va, filesz, memsz, kernel.peek32(ph + 4))) { return 0; };
        };
        i = i + 1;
    };
    entry
};

// The program's stack, mapped and given a first frame, and the %rsp to enter
// with.  `name` is what argv[0] says -- which is how two processes of one
// image tell each other apart.
def elf_setup_stack(args: [str]) -> long {
    let at = 0;
    while (at < STACK_BYTES) {
        let got = kernel.page_alloc();
        if (got == 0) { return 0; };
        if (!kernel.vm_map(kernel.vm_current(), STACK_BASE + at, got, kernel.PTE_U | kernel.PTE_W)) { return 0; };
        at = at + 4096;
    };
    elf_stack(STACK_BASE + STACK_BYTES - 16, args)
};

// Load the image at `phys` (`size` bytes) into the current address space and
// leave for ring 3.  Returns 0 if the image cannot be run, and never returns
// when it can.
def elf_load(phys: long, size: long, args: [str]) -> long {
    let entry = elf_map(phys, size);
    if (entry == 0) { return 0; };
    let sp = elf_setup_stack(args);
    if (sp == 0) { return 0; };
    kernel.enter_user(entry, sp, 514);
    0
};
