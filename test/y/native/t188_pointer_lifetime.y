// A pointer is valid while what it points into is live (m5). `&x` on a local
// or a parameter is a cell in that function's frame, and the frame is gone
// when the function returns: such a pointer must not escape, and nothing
// catches it if it does -- the manual's pointers section is what says so.
// What is safe outlives every frame: a global's storage is permanent, and a
// heap array's elements and a fixed array's live in a heap cell, so &a[i] is
// fine to pass around and to store.
let global: long = 7;
let heap: [long] = [10, 20, 30];
let fixed: [long; 3] = [1, 2, 3];

// A pointer into a frame, used inside that frame: the supported shape.
def within_frame() -> long {
    let local: long = 5;
    let p = &local;
    *p = *p + 1;
    let a = [&local, p];
    *a[0] + *a[1]
};
print(within_frame());

// Handed to another function and read there, with the caller still live.
def bump(p: *long) -> long { *p = *p + 10; *p };
print(bump(&global), " ", global);

// An element's address outlives the frame that took it.
def elem_addr() -> *long { &heap[1] };
let ep = elem_addr();
let fp = &fixed[2];
def churn(n: long) -> long {
    let a = n;
    let b = n + 1;
    a + b
};
print(churn(1), churn(2), churn(3), churn(4), churn(5), churn(6), churn(7));
print(*ep, " ", *fp, " ", global, " ", heap[1], " ", fixed[2]);

// A pointer to a local, returned out of its frame, is not a type error -- it
// reads whatever the stack holds by then, and that is not the same from run to
// run, so there is nothing here to read and nothing to pin. The rule is in
// docs/src/08-functions.tex. This is only here so the program keeps the value
// alive without ever dereferencing it.
def expires_unused(p: *long) -> long { 0 };
def escapes() -> *long {
    let local: long = 111;
    &local
};
let escaped = escapes();
expires_unused(escaped);
print(*(&heap[0]) + *(&fixed[0]));
print("a pointer that escaped its frame exists and is never read");
