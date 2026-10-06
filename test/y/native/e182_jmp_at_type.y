// expect-error: 2:25: error: jmp_at needs an address, got str
def f() -> void { jmp_at("x"); 0 };
f();
