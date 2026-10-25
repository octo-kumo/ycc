// segv -- touch an unmapped address: the kernel must end this task (exit status
// 139) and leave the shell running.
let p: *long = ptr_from(8);
puts("before\n");
*p = 1;
puts("not reached\n");
