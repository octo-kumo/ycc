// M1, step 1: the CPU's descriptor tables, built by Y and loaded by two
// instructions.  A bad descriptor faults *here*, before the IDT exists, so
// this case is the bring-up gate for the ring-3 work.
import kernel;

kernel.init();

print("gdtr limit: " + tostring(55));
print("tr selector: " + tostring(kernel.tr_get()));
print("tr is the TSS: " + tostring(kernel.tr_get() == kernel.SEL_TSS));
print("tss descriptor is present: " + tostring(kernel.tss_desc_lo(4096, 103) != 0));
print("kernel stack top: " + tostring(kernel.kernel_stack_top() > 0));
kernel.kexit(0);
