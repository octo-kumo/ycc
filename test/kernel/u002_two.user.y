// Two processes of ONE image: argv[0] tells them apart, and what makes them
// two is an address space each.
let a = argv();
puts("process ");
puts(a[0]);
puts("\n");
