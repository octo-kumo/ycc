// Regions are one-thread only: once a thread has been spawned, the allocator's
// block is per thread, and an explicit region traps (arch/regions.s
// y_region_enter). A spawn inside a region is refused at compile time
// (escape.y); a loop body the compiler would make a region simply stays the
// collector's once threads run (y_region_auto_enter).
def worker() { print("worker"); }
print("before");
let t = spawn(worker);
join(t);
let total = 0;
for i in 0..3 {
    let s = "x" + tostring(i);
    total += s.length;
}
print(total);
region {
    print("never");
}
print("after");
