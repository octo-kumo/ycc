// Platform policy is independent of the instruction encoder. Runtime files
// replace whole labelled blocks; register numbers name the shared packed IR.
const TARGET_ARCH = { name: "x86_64", word: 8, endian: "little" };
// name | object writer | runtime sources | threads | syscall registers |
// stack argument area | first stack argument offset
const TARGET_PLATFORMS = [
    "linux|elf|prelude|threads|7,6,2,10,8,9|0|0",
    "win|pe|prelude,wsys,wproc,wnet,wcon,wgui|wthreads|10,2,8,9|96|40",
    "kernel|kelf|prelude,kernel|threads|7,6,2,10,8,9|0|0",
    "web|wasm|prelude,web|threads|7,6,2,10,8,9|0|0",
];
export { TARGET_ARCH, TARGET_PLATFORMS };
