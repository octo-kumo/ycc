// print(<integer>) formats the digits into a stack buffer (arch y_print_int),
// so it allocates nothing: a program that only prints numbers never links the
// allocator -- or the collector behind it -- and a print in a hot loop does
// not grow the heap. The float/bigint/str/array paths still build a string.
let h = heap_used();
print(0);
print(-1);
print(9223372036854775807);
print(1 + 2);
print(200);
let b: byte = 250;
print(b);
if (heap_used() == h) { print("no alloc"); } else { print("allocs"); };
