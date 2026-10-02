# Projects, dependencies and linking — design proposal

Status: **decided — L2 + D1/D3 + O2 + K2, std first.** Stage 1 is
implemented: the std modules are separately compiled units that ycc links
into programs, precompiled into a pack attached to the ycc binary (NATIVE.md,
"Compilation units and the std pack"). Stage 3 is implemented too: a
`y.toml` manifest, path and git dependencies (pinned in `y.lock`, or copied
by `ycc vendor`), each package compiled once into a cached object under
`build/obj` and linked, `ycc build` (NATIVE.md, "Packages"; the manual's
Packages subsection; `test/sh/test_pkg.sh`).
The text below is the original proposal.
Today an `import` is a compile-time text splice (`native_resolve` in
`src/y/native.y`): every build re-reads, re-checks and re-emits every module
it reaches, std included, and tree shaking runs over the whole program. That
is simple and keeps whole-program shaking, but nothing is ever reused between
builds — self-compiling ycc (≈600 KB of spliced source) takes ~6 s, and a
project with large dependencies would pay for all of them on every build.

The decision has four axes. Each lists the options with their costs; the
composite designs at the end pick one option per axis.

## 1. Project layout

| Option | Shape | For | Against |
|---|---|---|---|
| L1 convention | `y.toml` at the root, `src/main.y` (program) or `src/lib.y` (library), `test/*.y`, output in `build/` | zero configuration, every project looks the same | one entry point per package unless the manifest lists more |
| L2 manifest-only | any layout; `y.toml` lists entry points and source roots | fits existing trees | every project is different; tools must read the manifest first |

## 2. Declaring and resolving dependencies

| Option | How | For | Against |
|---|---|---|---|
| D1 git URLs + lockfile | `[deps] json = { git = "https://…/json.git", tag = "v1.2" }`; `y.lock` pins the commit hash and a content hash | no server to run; reproducible; works for private repos | no version ranges, so diamond conflicts are resolved by hand (or by MVS, below) |
| D2 registry + semver | `json = "^1.2"` resolved against an index (crates.io/npm style) | familiar; version ranges; search | needs a hosted index and publishing workflow; resolver complexity |
| D3 vendoring | dependencies are copied into `vendor/` and committed | hermetic; no network at build time; trivial to implement | updates are manual; repository bloat |

Resolution for D1/D2: **minimal version selection** (Go) picks, for each
package, the highest of the minimum versions anyone asks for — deterministic,
no SAT solver, and the lockfile is just a cache of the answer.

Imports would name a dependency the way std modules are named today:
`import json;` (a dependency or std module) next to the existing
`import x from "./path.y";` (a file in the same package).

`ycc` is a static ELF without TLS, so fetching goes through `git` (via
`exec`, or a small separate `ypkg` tool so that `ycc --no-exec` stays a
pure compiler).

## 3. What a compiled dependency looks like ("prebuilt, no rebuild")

| Option | Artifact | For | Against |
|---|---|---|---|
| O1 none (status quo) | sources only; every build splices and recompiles everything | no format, no linker, whole-program shaking and inference for free | build time grows with all transitive dependencies |
| O2 `.yo` — ycc's own relocatable object | per module: an **interface** (exported names with their checked/inferred types, record shapes, aliases) + machine code **one section per function** + rodata + relocations; ycc links them | rebuild only what changed; std ships prebuilt (the `std-objects` item); per-function sections keep tree shaking at link time; format can follow the compiler (no external ABI) | needs an object writer, an interface reader in the checker, and a linker; objects are tied to a compiler version (cache key includes it) |
| O3 standard ELF `ET_REL` `.o` | same content as O2 in ELF relocatable form (`.symtab`, `.rela.text`, one `.text.<fn>` per function), interface in a custom section | readable by `nm`/`objdump`/`perf`; links with `ld` if ever wanted; C interop becomes possible later | more format work than O2 (ELF section/relocation rules), same linker work in ycc |

Where prebuilt objects come from:

- **Local cache** (`~/.cache/y/obj/<hash>.yo`, key = source hash + compiler
  hash + flags): a dependency is compiled once per machine and reused by
  every project. Safe and simple.
- **Shared binary cache** (optional, later): the same keys served over HTTP,
  so CI or a team never compiles a dependency at all. There is a single
  target (x86-64 Linux, static), so one artifact per key suffices.

## 4. Linking

| Option | How | For | Against |
|---|---|---|---|
| K1 splice (status quo) | no linking: one program text | nothing to build | no reuse (see O1) |
| K2 ycc links | `ycc` reads objects, resolves symbols, applies relocations, drops unreachable function sections, writes the ELF it already writes | no external tools (keeps "no cc/as/ld"); whole-program shaking survives at function granularity | ycc gains a linker (~1–2k lines in each copy, Y and C) |
| K3 system `ld` | emit O3 objects and call `ld` | least code | breaks the self-contained toolchain; `--gc-sections` is coarser than today's shaking |

Cross-module type inference is the subtle part of O2/O3/K2: return types
are inferred today, so the interface must record the *inferred* signature,
and a module is recompiled when the interface of anything it imports
changes (the hash covers dependency interfaces, not just its own source).

## Composite designs

- **A — source packages, local object cache, ycc links** (L1 + D1 + O2 + K2,
  recommended). `y.toml` + `y.lock` with git dependencies pinned by hash;
  every module compiles once into a cached `.yo`; ycc links and shakes per
  function. Std becomes a set of prebuilt objects shipped next to ycc (or
  embedded in it), which is exactly what the `std-objects` item needs.
  Cost: object format + interface files + linker, in both copies.
- **B — registry with prebuilt binary packages** (L1 + D2 + O3 + K2, shared
  binary cache from day one). Most convenient for users, most
  infrastructure: a hosted index, publishing, semver resolution, and a
  promise about object compatibility across compiler versions.
- **C — vendored sources, keep splicing** (L1 + D3 + O1 + K1). A manifest
  and a `vendor/` directory on top of today's splice, nothing else. Cheapest
  by far and keeps whole-program inference, but every build recompiles
  every dependency and std stays embedded text.
