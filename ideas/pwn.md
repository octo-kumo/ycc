**The three highest-leverage additions are: (1) bitwise/shift operators — they're genuinely absent and `struct.y` is emulating them with `/256` and `%256`; (2) method-call sugar on record type aliases, so `c.sendline(x)` can rewrite to `conn_sendline(c, x)` with no runtime machinery; (3) a buffered `pwn.y` std module layered on the existing `net.y` with `recvuntil`/`sendafter`/`interactive` and `ppoll`-based timeouts.** Everything else below is sugar around those.

## What I read from the repo

Y is a small, statically-checked imperative language with braces, no classes, and a deliberately tiny surface: `let`/`def`, structural records, dynamic maps, heap/fixed arrays, options with `none`/`x!`, raw pointers, closures, and unions with `match`【turn1fetch0】【turn1fetch1】. The std modules are ordinary Y spliced in by `import net;`-style imports under a flat namespace (`net.foo` is stripped to `foo` at compile time), with an `export { ... }` clause at the end of each file and flat, verb-suffixed names chosen to avoid collisions (`close_fd` because `io.y` owns `close`)【turn1fetch0】. The error contract is C-flavored: syscalls return an fd or a negative errno, reads that can hit EOF return `str?`【turn1fetch1】. There is a stated rule that the backend provides small general primitives (`syscall`, `bytes`/`from_bytes`) and the *behaviour* lives in spliced Y that compiles like any other function and is tree-shaken when unused【turn1fetch2】. Any proposal that fits that shape — std-first, compiler changes small and orthogonal — will land cleanly.

Two facts from the docs pin the design below: the binary operator table currently has *no* `& | ^ << >> ~` at all, and `struct.y` works around it with `low_byte(v) = v % 256` / `shr8(v) = (v - low_byte(v)) / 256`【turn5fetch0】【turn2fetch2】. Also, `recv_str` does a single `read(2)` into a 4096-byte local buffer and returns — bytes past the ask are silently dropped【turn1fetch0】, which is fine for `http_read_head` and fatal for `recvuntil` protocols.

## Target script (the north star)

This is what a CTF script should look like in Y after the changes, next to the equivalent pwntools program:

```y
// solve.y
import pwn;

def main() -> long {
    // one call to connect; `!` traps on none, which is what a pwn script wants
    let c = pwn.remote("chal.local", 1337)!;

    // method sugar: c.sendafter(m, p) == conn_sendafter(c, m, p)
    c.sendlineafter("Enter your name: ", "kay");
    c.sendafter("Enter your choice: ", "2");

    // [byte] repetition, little-endian u64 pack (pwntools p64 defaults)
    let payload = b"A" * 40 + p64(0x40123a);
    c.sendline_b(payload);

    // offsets without the guess-and-check loop
    c.sendline(cyclic(200));
    let leak = c.recvline()!;
    let win  = u64(bytes(leak[8:16]) + b"\x00\x00");

    eputs("win at " + hex(win) + "\n");
    c.interactive();
    0
};
```

Every construct above is either already in Y or justified by a numbered feature below.

## Proposed std module: `pwn.y`

No compiler changes required for this module — it sits on `net.y`, `io.y`, `struct.y`, and the `syscall` intrinsic. The one thing it adds that `net.y` cannot express today is an **internal recv buffer**: `recvuntil` must keep bytes past the marker for the next call, so the connection is a record, not a bare fd.

```y
// std/pwn.y — a pwntools-shaped tube over net.y, plus exploit helpers.
//
// A Conn is a plain record: the fd plus whatever a buffered recv has
// already pulled off the wire but not handed to the caller yet. That
// buffer is the whole point — recvuntil MUST NOT lose bytes past the
// marker, and net.recv_str drops them by design (one read(2), surplus
// discarded). Every recv here goes through conn_fill, which appends
// into c.buf and consumes from the front.
//
// Timeouts are ppoll (syscall 271) on the fd, so recvuntil / clean /
// interactive can all run with a deadline instead of blocking forever.
// On timeout the conn is left exactly as it was — buf intact, nothing
// half-consumed — so a caller can retry or bail cleanly.

type Conn = { fd: long, buf: [byte], closed: bool, timeout_ms: long };

// ── lifecycle ────────────────────────────────────────────────────────
def remote(host: str, port: long) -> Conn?;   // connect_tcp + a fresh Conn
def listen_fork(port: long, h: (Conn) -> long) -> long;
    // bind + listen + fork(57) per accept; the child runs h(c) then
    // exit(0), the parent closes c, loops, and reaps via
    // rt_sigaction(SIGCHLD, SIG_IGN). A forking server in ~20 lines.
def conn_close(c: Conn) -> long;              // close_fd + closed = true
def conn_shutdown(c: Conn, how: long) -> long;

// ── send ─────────────────────────────────────────────────────────────
def conn_send(c: Conn, s: str) -> long;       // full write loop, no short sends
def conn_sendline(c: Conn, s: str) -> long;   // s + "\n"
def conn_send_b(c: Conn, b: [byte]) -> long;  // bytes are a separate type; both spellings
def conn_sendline_b(c: Conn, b: [byte]) -> long;
def conn_sendafter(c: Conn, marker: str, s: str) -> long;
def conn_sendlineafter(c: Conn, marker: str, s: str) -> long;

// ── recv ─────────────────────────────────────────────────────────────
def conn_recv(c: Conn, n: long) -> str?;      // up to n buffered-or-read bytes
def conn_recvn(c: Conn, n: long) -> str?;     // exactly n, none on early EOF
def conn_recvline(c: Conn) -> str?;           // through "\n", newline stripped
def conn_recvuntil(c: Conn, m: str) -> str?;  // through the FIRST m; surplus stays in buf
def conn_clean(c: Conn) -> long;              // drain whatever arrives in c.timeout_ms
def conn_settimeout(c: Conn, ms: long) -> long;

// ── interactive ──────────────────────────────────────────────────────
def conn_interactive(c: Conn) -> long;
    // ppoll(0, stdin) and ppoll(fd) alternately; forward raw bytes both
    // ways until the socket dies or stdin hits EOF. One fd-set on the
    // stack, two 4096-byte bounce buffers, nothing else.

// ── packing, over struct.y ───────────────────────────────────────────
def p64(v: long) -> [byte];                   // = struct.u64le  (pwntools default)
def p64be(v: long) -> [byte];                 // = struct.u64be
def p32(v: long) -> [byte];  def p32be(v: long) -> [byte];
def u64(b: [byte]) -> long;  def u64be(b: [byte]) -> long;
def u32(b: [byte]) -> long;  def u32be(b: [byte]) -> long;
def p64s(v: long) -> [byte]; def u64s(b: [byte]) -> long;  // signed spellings

// ── offsets ──────────────────────────────────────────────────────────
def cyclic(n: long) -> str;                   // de Bruijn over "abcdefghijklmnopqrstuvwxyz"
def cyclic_find(pat: str) -> long;            // offset of the first occurrence, or -1
def repeat(b: [byte], n: long) -> [byte];     // what `b"A" * 40` desugars to
def hex(v: long) -> str;                      // "0x" + lowercase, no sign games

export { Conn, remote, listen_fork, conn_close, conn_shutdown,
         conn_send, conn_sendline, conn_send_b, conn_sendline_b,
         conn_sendafter, conn_sendlineafter,
         conn_recv, conn_recvn, conn_recvline, conn_recvuntil,
         conn_clean, conn_settimeout, conn_interactive,
         p64, p64be, p32, p32be, u64, u64be, u32, u32be, p64s, u64s,
         cyclic, cyclic_find, repeat, hex };
```

The mapping to what you already have:

| pwn.y | pwntools | lands where |
|---|---|---|
| `remote` / `conn_close` | `remote()` / `r.close()` | std only |
| `send` / `sendline` | `r.send` / `r.sendline` | std only |
| `recvuntil` / `recvn` / `recvline` | same names | std only; needs the `Conn` buffer |
| `sendafter` / `sendlineafter` | same names | std only |
| `interactive()` | `r.interactive()` | std only, over `ppoll` |
| `clean()` | `r.clean(timeout)` | std only, over `ppoll` |
| `p64`/`u64`/`p32`/`u32` family | same names | std only, thin over `struct.y` |
| `cyclic` / `cyclic_find` | same names | std only |
| `listen_fork` | — (pwntools' `listen()` + threads) | std only, over `syscall(57)` |
| `asm` / `shellcraft` | same | **stretch**: ycc already contains an x86-64 encoder (`enc64.y`); exposing it as a build-time hook is a separate project, not a std file |

The TODO already flags that `net.y`'s error paths and `listen_tcp` are untested precisely because they block forever【turn2fetch0】 — `conn_settimeout` fixes the testability problem at the same time as the ergonomics problem.

## Proposed language features

### 1. Bitwise and shift operators — `& | ^ << >> ~`

The biggest gap for exploit work, full stop. Addresses, ROP chain assembly, flag math, and every `p64`-style task want these; today `struct.y` fakes shifts with division and masking with modulo, which only works because someone was careful about negative values【turn2fetch2】. The operator table just doesn't have them【turn5fetch0】.

- Syntax: binary `&`, `|`, `^`, `<<`, `>>` on `long` and `byte`; unary `~`; compound forms `&= |= ^= <<= >>=` join the existing `p op= e` desugar (the doc says the compound set is `{+,-,×,÷,%}` — widening it is the same one-line change)【turn5fetch0】.
- Precedence: C-relative, slotted around the existing table — `<<`/`>>` bind tighter than comparisons but looser than `+ -`; then `&`, then `^`, then `|` between there and `==`. Right-shift is arithmetic on `long` (matching `shr8`'s intent).
- Cost: a few rows in `enc64.y` and the checker. No new semantics — x86-64 has the instructions.

This unblocks `p64` being written as eight real shifts, hex printing, `cyclic_find` doing index math, and any gadget/flag work. It should be first.

### 2. Method-call sugar on record type aliases

You have structural records and first-class closures but no dispatch, and you don't want dispatch. The cheap version is a **rename**, and the rename pass is exactly where it belongs — `rename.y` already rewrites `net.foo` to `foo`【turn1fetch0】.

- Syntax: nothing new. `c.sendline("x")` is just today's postfix `.name(args)`.
- Resolution rule: for `x.m(args)` where `x`'s static type is a **named** record alias `T` (declared with the existing `type Conn = { ... };` form【turn2fetch0】), rewrite to `conn_m(x, args)` — lowercased alias name, underscore, method. If no such def is in scope, it's the ordinary "undefined function" error. Shape-hole records (`{ k: str }`) and anonymous record literals get no resolution, so nothing surprising happens.
- Semantics: purely syntactic. `c` is evaluated once because it's just the first argument of an ordinary call. No vtables, no dynamic dispatch, no subtyping, nothing to specify beyond the rewrite.

This one feature is what makes the std module *read* like pwntools instead of like a C header. If even that feels heavy, the cheaper and more general alternative is a pipe operator, `c |> sendline("x")` desugaring to `sendline(c, "x")` — works on any first argument, not just records, but it doesn't read as fluently on chained calls. Method sugar on aliases is the better fit for this codebase; the pipe is the fallback.

### 3. `str` indexing and slicing sugar

The grammar already has slices on arrays (`b[k:24]` appears in `rt.y`'s own code) and the postfix row already allows `[expr ? : expr ?]`【turn2fetch0】. Extending the same postfix forms to `str` removes a wall of `substr`/`byte_at` calls in payload-parsing code:

- `s[i]` → `byte_at(s, i)` as a `long` (the builtin already exists and is documented as the cheap per-byte access path【turn2fetch3】).
- `s[i:j]` → `substr(s, i, j - i)`, with the same C-clamping semantics `substr` already documents.
- Optional: `s[i:]` and `s[:j]` fill the missing side, matching pwntools' slice habits.

Pure desugar, no new types, no new evaluation rules.

### 4. String interpolation

`"port is {port}, pid {pid}\n"` desugars to `"port is " + tostring(port) + ", pid " + tostring(pid) + "\n"`. Y already auto-stringifies one side of `+` when the other is a `str`【turn3fetch1】, so this introduces no new formatting rules — it only kills the `+` noise. `{{` and `}}` are the escapes. Build logs, banner parsing, and `sendlineafter` prompts get dramatically shorter, and the desugar reuses `tostring` verbatim so record/map formatting stays consistent.

### 5. `if let` for options

Today's examples are full of this dance (it's visible in `net.y` and `ysh.y`): `if (is_some(x)) { use(unwrap(x)) }` or `x = recv(); while (x != none) { lines += x!; x = recv(); }`. One small grammar form kills it:

```
if let some(x) = expr { ... } else { ... }
```

desugars to

```
{ let __t = expr; if (is_some(__t)) { let x = unwrap(__t); ... } else { ... } }
```

with `x` scoped to the then-arm. It's the same size of change as the postfix `!` unwrap that already exists【turn4fetch1】, and it composes with the `-> str?` contract the std already uses everywhere.

### 6. `?` propagation on options

Companion to `if let`, and the same one rule: in a def whose return type is `T?`, the postfix `?` on an option expression early-returns `none` on empty:

```
expr?
// ≡ { let __t = expr; if (is_some(__t)) { unwrap(__t) } else { return none; } }
```

This is what makes helper chains like `let line = c.recvline()?;` natural in parsers without introducing exceptions (Y has none, and shouldn't). For the negative-errno `long` contract, no compiler change is needed — a `type Res = Ok(long) | Err(long);` union plus `ok()`/`err()`/`and_then` helpers in `pwn.y` covers the cases where a caller wants to distinguish errno values; unions with `match` already exist【turn1fetch0】.

### 7. `using` — scoped disposal for fds

There are no exceptions, so disposal is purely lexical, which makes this feature unusually cheap to specify:

```
using c = pwn.remote("h", 1337) by conn_close {
    c.sendline("hi");
    if (bad) { return 1; }      // the rewrite inserts conn_close(c) before this return
    c.interactive();
};
```

desugars to a block that binds `c`, runs the body, and calls the explicitly-named disposer at *every* exit of the block — fall-through, `return`, and the `--prof` exit path. The rewrite is the same complexity class as the exactly-once capture rule the language already specifies for compound assignment【turn5fetch0】. Without it, every `recvuntil`-style script is one early `return` away from leaking an fd; `net.y` already had to think about this once (failed `connect` closes the socket before returning the errno)【turn1fetch0】 — `using` generalizes that discipline.

### 8. `fork { }` — and why it's nearly free

`future.y` already sketches `spawn { }` with mutexes and semaphores【turn2fetch1】. For the pwn use-case the cheap subset is a **process** fork, and it needs no new intrinsic at all — `syscall(57)` is `fork(2)` today under the existing `syscall` contract, and `exit(0)` is already an intrinsic. So `listen_fork` is writable *right now* as std. The only language-side nicety worth adding later is block sugar:

```
let pid = fork { ...child code... };   // none in the child, some(pid) in the parent
```

desugaring to the explicit `syscall(57)` + `if (pid == 0)` form. Keep it low priority — the std function delivers the value on its own, and threads/locks per `future.y` can be designed on top later without re-litigating this.

### 9. Array/byte-string repetition `*`

`b"A" * 40` desugars to `repeat(b"A", 40)`. It's a one-row addition to the operator table (same precedence as `*`) and it removes the most common single line of noise in exploit payloads. If you'd rather not grow the operator set, `repeat` as a std helper is fine — but the operator reads much better in the north-star script.

### 10. `StrBuf` — deferred

`str +=` already concatenates today (it's the one legal compound form on string targets【turn5fetch0】), but each step copies, and the TODO already calls out the O(n²) `concat` path as a known cost【turn2fetch0】. A `StrBuf` record over a heap `[byte]` with amortized growth would fix the hot path, but it's a perf fix, not an expressiveness fix — `from_bytes`/`bytes` already bridge the two worlds. Do it when the `y_alloc`/brk caching item in the TODO lands, not before.

## Suggested landing order

1. **Bitwise/shift operators** — small compiler patch, unblocks everything in `p64`/`hex`/gadget code, zero semantic risk.
2. **`pwn.y` std module** — no compiler change at all; lands today on `net.y` + `syscall` + `struct.y`, and the `Conn` buffer is the one genuinely new idea. Testable against a local `listen_fork` target, which also closes the "untested net paths" gap in the TODO.
3. **`str` slices + repetition + interpolation** — three small desugars in the parser, big ergonomic payoff in every script.
4. **Method-call sugar on `type` aliases** — the rename-pass rewrite; this is the feature that makes the API feel native rather than prefixed.
5. **`if let`, `?`, `using`** — the control-flow trio; each is one rule, and together they remove most of the remaining boilerplate in real exploit scripts.
6. **`fork { }` sugar and `StrBuf`** — only after `future.y`'s concurrency sketch and the allocator work settle, so the syntax doesn't have to be revisited.

Everything in tiers 1–3 can land without touching the type checker's semantics; tier 4 is the only change that needs a new (small, purely syntactic) resolution rule, and it slots into the pass that already handles namespace stripping.