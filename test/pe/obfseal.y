// flags: --ob --ob-seed=9
// A sealed PE: the stub decrypts the code after itself and the whole .rodata
// before _start. The literal is checked twice so the data side is exercised.
let msg = "PE SEAL OK";
def main() -> long {
    print(msg + " " + tostring(len(msg)));
    print("second literal survives");
    0
};
let r = main();
