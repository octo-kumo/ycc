// ntfile_probe.y -- the WORKING PROOF behind "File I/O is Y, not assembly"
// in ideas/WINDOWS.md. Not part of any build and not a fixture: it is the
// design record, kept runnable so a future reader can check the claim
// instead of taking it on trust.
//
//   ycc --target=windows ideas/ntfile_probe.y -o /tmp/ntfile.exe
//   wine /tmp/ntfile.exe <a file under the prefix drive>
//
// It opens a file with NtOpenFile and reads it with NtReadFile, with no
// imports, no new arch code and no raw syscall in std -- every byte of the
// NT plumbing (UNICODE_STRING, OBJECT_ATTRIBUTES, IO_STATUS_BLOCK, the
// \??\ namespace prefix) is built here in Y and handed to the syscall
// intrinsic. On Linux the same source fails to compile, which is the point:
// the numbers are Windows' and belong behind a label.
//
// The four traps this walks into, each worth a comment where it happens:
// an access mask COMPUTED (0x120089 = 1179785), a namespace prefix of ONE
// backslash before ??, options 96 and not 33, and NtCreateFile's 11
// arguments against the intrinsic's 10-argument Windows ceiling.
// PROOF OF CONCEPT: NT file I/O built in Y, no assembly.
//
// The design test for the "no raw syscalls in std" port: if a Y function can
// build an OBJECT_ATTRIBUTES and call NtCreateFile/NtReadFile with the
// syscall intrinsic, then the whole fs surface is Y with one shared shape and
// the arch module only has to supply the numbers (w_sysno) -- no 13 hand
// written assembly entry points.
//
// Layouts are the documented x64 ones and the numbers were read out of a real
// ntdll's export table (see the commit message), not from memory.

// ── little-endian stores into a byte buffer ────────────────────────────
def put16(b: [byte], off: long, v: long) -> long {
    b[off] = v & 255;
    b[off + 1] = (v >> 8) & 255;
    0
};

def put32(b: [byte], off: long, v: long) -> long {
    put16(b, off, v);
    put16(b, off + 2, v >> 16);
    0
};

def put64(b: [byte], off: long, v: long) -> long {
    put32(b, off, v);
    put32(b, off + 4, v >> 32);
    0
};

def hex(v: long) -> str {
    let d = "0123456789abcdef";
    let s = "";
    let i = 0;
    while (i < 16) {
        s = chr(byte_at(d, (v >> (i * 4)) & 15)) + s;
        i = i + 1;
    };
    s
};

// ── a DOS path as a UTF-16 buffer plus its UNICODE_STRING header ───────
// UNICODE_STRING is 16 bytes: Length u16 (bytes, NUL excluded), MaximumLength
// u16, 4 bytes padding, then the PWSTR at +8. NtCreateFile wants the object
// name in the \??\ namespace, which is where a DOS drive letter lives.
def nt_path(dst: [byte], out_off: long, path: str) -> long {
    let n = len(path);
    let i = 0;
    while (i < n) {
        // widening ASCII to UTF-16: the high byte of each unit is zero, which
        // is exactly what a BMP code point below 0x80 looks like
        dst[out_off + i * 2] = ord(path[i:i + 1]);
        dst[out_off + i * 2 + 1] = 0;
        i = i + 1;
    };
    dst[out_off + n * 2] = 0;
    dst[out_off + n * 2 + 1] = 0;
    n * 2
};

def main(args: [str]) -> long {
    // usage: ntfile.exe \??\Z:\path\to\file
    // One buffer for everything: 512 bytes of name, then the UNICODE_STRING,
    // then OBJECT_ATTRIBUTES, then IO_STATUS_BLOCK, then the handle.
    let b: [byte] = [];
    let zi = 0;
    while (zi < 1024) { b += 0; zi = zi + 1; };
    let NAME = 0;
    let US = 512;          // UNICODE_STRING
    let OA = 528;          // OBJECT_ATTRIBUTES (48 bytes)
    let IOSB = 576;        // IO_STATUS_BLOCK (16)
    let HAND = 592;        // the returned handle

    // THE PATH, and this is the finding: an argument that names a file comes
    // through argv ALREADY as a Windows path. Wine (and the Windows loader
    // behind it) rewrite a Unix path in the command line to its DOS form, so
    // argv[0] and every path argument read "Z:\tmp\...\file", never
    // "/tmp/.../file". A PE does not have to translate anything for the
    // paths a user actually types -- which is most of what fs.y would
    // otherwise have to do.
    //
    // NtOpenFile wants the object-manager form \??\Z:\...: one backslash
    // before ??. Two gives STATUS_OBJECT_PATH_NOT_FOUND, and none at all
    // gives STATUS_OBJECT_NAME_INVALID. chr(92) keeps every one of those
    // out of the reader's and the shell's escaping rules.
    //
    // A path that does NOT already look like a drive (someone passed a bare
    // name) gets \??\ prepended as a relative object name.
    let src = args[1];
    let name = "";
    if (src[0:1] == "/") {
        // a Unix path that reached us untranslated: map it onto the Z: drive,
        // which is the prefix's root, dropping the leading separator because
        // Z: already carries one
        name = chr(92) + "??" + chr(92) + "Z:" + chr(92);
        let ci2 = 1;
        while (ci2 < len(src)) {
            let ch2 = src[ci2:ci2 + 1];
            if (ch2 == "/") { name = name + chr(92); } else { name = name + ch2; };
            ci2 = ci2 + 1;
        };
    } else {
        // already a Windows path: prepend the namespace only. Separators are
        // normalized anyway, because a user may have typed forward slashes.
        name = chr(92) + "??" + chr(92);
        let ci3 = 0;
        while (ci3 < len(src)) {
            let ch3 = src[ci3:ci3 + 1];
            if (ch3 == "/") { name = name + chr(92); } else { name = name + ch3; };
            ci3 = ci3 + 1;
        };
    };
    let nbytes = nt_path(b, NAME, name);
    let dbg = "";
    let di = 0;
    while (di < nbytes) {
        let cv = b[NAME + di * 2];
        dbg = dbg + (if (cv == 92) { "<bs>" } else { chr(cv) });
        di = di + 1;
    };
    print("name=" + dbg + " len=" + tostring(nbytes) + "\n");
    let nameptr = ptr_addr(&b[0]) + NAME;

    // UNICODE_STRING { Length, MaximumLength, pad, Buffer }
    put16(b, US + 0, nbytes);
    put16(b, US + 2, nbytes + 2);
    put64(b, US + 8, nameptr);

    // OBJECT_ATTRIBUTES { Length=48, RootDirectory=NULL, ObjectName, Attributes=0,
    //                     SecurityDescriptor=NULL, SecurityQualityOfService=NULL }
    put32(b, OA + 0, 48);
    put64(b, OA + 8, 0);
    put64(b, OA + 16, ptr_addr(&b[0]) + US);
    put32(b, OA + 24, 64);
    put64(b, OA + 32, 0);
    put64(b, OA + 40, 0);

    // NtCreateFile(handle, access, oa, iosb, allocsize, fileattrs, share,
    //              disposition, options, eabuf, ealen)
    //   access      FILE_GENERIC_READ 0x120089
    //   share       READ|WRITE|DELETE 7
    //   disposition FILE_OPEN 1
    //   options     FILE_NON_DIRECTORY_FILE|FILE_SYNCHRONOUS_IO_NONALERT
    //               = 0x40 | 0x20 = 96
    // NtCreateFile takes 11 arguments and the syscall intrinsic caps at 9
    // (number + 9), so this is NtOpenFile instead -- 6 arguments, and it takes
    // the same OBJECT_ATTRIBUTES:
    //   NtOpenFile(handle, access, oa, iosb, share, options)
    let status = syscall(51,
        ptr_addr(&b[0]) + HAND,
        1179785,
        ptr_addr(&b[0]) + OA,
        ptr_addr(&b[0]) + IOSB,
        7,
        96);
    print("NtOpenFile   status = 0x" + hex(status) + "\n");
    if (status < 0) { print("FAILED (NTSTATUS is negative on failure)\n"); 1 } else {
        let handle = 0;
        // read the handle back out of the buffer
        let i = 0;
        while (i < 8) {
            handle = handle + (b[HAND + i] << (i * 8));
            i = i + 1;
        };
        print("handle = 0x" + hex(handle) + "\n");

        // NtReadFile(handle, event, apcroutine, apccontext, iosb, buffer,
        //            length, offset, key)
        let buf: [byte] = [];
        let zj = 0;
        while (zj < 256) { buf += 0; zj = zj + 1; };
        let off: [long; 1] = [0; 1];
        let st2 = syscall(6, handle, 0, 0, 0,
            ptr_addr(&b[0]) + IOSB,
            ptr_addr(&buf[0]), 64,
            ptr_addr(&off[0]), 0);
        print("NtReadFile   status = 0x" + hex(st2) + "\n");
        // the byte count comes back in IOSB.Information at +8
        let got = b[IOSB + 8] + (b[IOSB + 9] << 8);
        print("bytes read = " + tostring(got) + "\n");
        let i2 = 0;
        let line = "";
        while (i2 < got) {
            line = line + chr(buf[i2]);
            i2 = i2 + 1;
        };
        print("first line: " + line[:24] + "\n");
        syscall(15, handle);
        0
    }
};

main(argv());
