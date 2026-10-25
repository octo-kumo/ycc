// expect-error: 2:25: error: jmp_at needs 1 argument (the address)
def f() -> void { jmp_at(); 0 };
f();
