// The runtime in a kernel: SSE float arithmetic, string building, arrays and
// the arena allocator all run as they do hosted.  The float line is the
// important one: it is why the trampoline sets CR4.OSFXSR, without which
// every SSE instruction is #UD and the machine stops at the first `mulsd`.
import kernel;

kernel.init();
puts("float: ");
print(3.5 * 2.0);
let s = "";
for i in 1..6 { s += tostring(i) + ","; };
puts("str: " + s + "\n");
let a: [long] = [];
for i in 0..200 { a += i * i; };
let sum = 0;
for i in 0..len(a) { sum += a[i]; };
print(sum);
kernel.halt();
