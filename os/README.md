# Y-OS

A small operating system written in Y: the `ycc --kernel` microkernel, a
filesystem, a shell and a handful of programs. It boots under qemu and you type
at it on the serial console.

    make run-os          # build, then boot on this terminal (Ctrl-A X leaves qemu)
    make os              # just build os/build/os.img and os/build/os.fs

You need `qemu-system-x86_64`. `halt` (or `exit`, or Ctrl-D on an empty line)
stops the machine.

## What is in it

| | |
|---|---|
| `os/kernel/boot.y` | the kernel program: starts the kernel, mounts the filesystem module where it lies in memory, loads `/sh` and runs it |
| `src/y/std/kernel.y` and friends | the kernel proper: memory, address spaces, scheduler, syscalls, console (`kmem`, `yfs`, `fd` are its parts); all of them travel in `ycc`'s std pack |
| `os/uland/ulib.y` | the programs' thin layer over the syscalls |
| `os/uland/*.y` | `sh` and the commands: `ls cat echo wc head cp rm mv write halt pwd` |
| `os/tools/mkfs.y` | packs the programs into a YFS1 image (`src/y/KERNEL.md` has the format) |

The programs are ordinary `ycc` programs: the kernel implements the Linux system
call interface the compiler's runtime already speaks (`openat`, `read`, `write`,
`getdents64`, `fork`, `execve`, `wait4`, `mmap` ...), so `os/uland/ls.y` runs on a
Linux host as well as here. (Not `halt`: it calls reboot(2).)

## The shell

One line at a time, split on spaces. `help`, `exit` and `halt` are built in;
everything else is a program in the root directory, started with fork, execve and
wait4. There is no quoting, no redirection, no pipes and no directory but `/`:
use `write FILE words...` to make a small file.

    Y-OS shell. Type help.
    $ write note.txt remember the milk
    $ cat note.txt
    remember the milk
    $ cp note.txt copy.txt
    $ ls

The filesystem lives in RAM: what you make is gone when the machine stops.

## Tests

`src/tools/ytest/yos.y` (suite `os`) builds the system with both compilers and checks
the images are identical, then boots scripted sessions (`test/os/*.cmds`) with
`ytest os-session` -- which sends each command only after the shell has printed its
prompt -- and compares the whole serial transcript with `test/os/*.expected`.
`ytest os-session CMD...` is also the way to script a session by hand.

## What is missing

Blocking input (the shell polls the serial port, so an idle shell spins the CPU),
directories and `cd`, redirection and pipes, a disk (the filesystem is the boot
module), and `ycc` itself running on it. `src/y/KERNEL.md` has the plan and the log.
