# Y Language Support (VS Code)

Language support for the Y programming language (the `ycc` language in this
repo), by way of `yserve`, the language server in `src/tools/lsp/`. The design
is `../LSP.md`.

## What it does today (milestones M1–M5)

- **Errors and warnings, together.** `yserve` runs the checker and the linter
  side by side, so one buffer can show both kinds of squiggle at once. The
  command line cannot do this: `compile_unit` returns before `lint_unit` when the
  checker found anything.
- **Diagnostics in imports.** A warning in an imported file is published against
  *that* file, not the one you are editing — one `publishDiagnostics` per file,
  as the protocol requires.
- **A missing import is a squiggle, not a crash.** The compiler handles an
  unresolvable `import` by printing and exiting; `yserve` finds it first.
- **Formatting.** *Format Document* (or **Y: Format Document**) rewrites the
  whole file with `src/tools/lsp/fmt.y`.
- **Syntax highlighting**, from the extension's own TextMate grammar
  (`syntaxes/y.tmLanguage.json`). It is registered in `contributes.grammars`, so
  every colour in a `.y` file comes from that grammar — no server request, and it
  works before `yserve` has started or after it has stopped.
- **Bracket pair colourisation is off for `.y`**, contributed as a
  `configurationDefaults` default: the grammar's comments and strings are the
  place a bracket is text rather than a pair, and disabling it for Y keeps that
  distinction out of VS Code's own line-based fallback. Every other language is
  untouched.
- **An outline**: `def`, `const`, `let`, `type`, `import` and `export`, nested,
  in the breadcrumb bar and the symbol picker. A `let` inside a loop is
  deliberately not an entry.
- **It does not die on a typo.** The server forks a handler per message, so the
  unterminated string literal you get halfway through typing a `"` is a
  diagnostic rather than a dead server.

Hover, go-to-definition and completion are advertised by the server and driven
from the open buffer's own declarations — see `src/extension.ts`.
Almost everything above needs **no code in this extension**: the client library
registers each request-shaped feature from the capability the server advertises,
and VS Code registers the TextMate grammar from `package.json`.

## Install

```sh
./ytest install-vscode          # make ytest first; --dry-run shows the steps
```

That builds the server (`make yserve`), builds and packages the extension
(`make lsp-vsix`), installs the `.vsix` with the `code` CLI, and copies `yserve`
next to the installed extension so nothing is left to configure. Add
`--dry-run` to see the steps without doing any of them, or `--help` for the two.

Then **Developer: Reload Window**, and open a `.y` file. The extension activates
on a `.y` file, so an editor that is already open has not started the server yet.

Two things to know, both printed again by the script:

- An extension **update** replaces its directory and the `yserve` copy with it.
  Re-run the script, or set `y.lsp.serverPath` (below), which survives one.
- Do not run the script under `ulimit -v`. The `code` CLI is Electron, which
  reserves far more *virtual* address space than it uses and dies under a cap
  with a trap that reads like "the install failed". `make`'s own recipes set a
  cap for every compile they start, so nothing needs one here.

## Requirements

If you are building by hand rather than with the script:

```sh
make yserve          # at the repository root
```

That produces `./yserve` at the root with the std units compiled and attached.
The extension looks for it, in this order:

1. `y.lsp.serverPath`, if you have set it. This is used **alone** — if it is
   wrong you get an error naming it, rather than a silent fallback to a
   different binary.
2. Next to the extension, then one and two directories up (so an unpacked
   extension inside the repo finds the repository's binary).
3. In the workspace root, and in `yserve/` under it.

`PATH` is deliberately **not** searched: `spawn` resolving a bare name works in a
shell and fails in VS Code, or picks up something unrelated. If it is on your
`PATH`, set `y.lsp.serverPath`.

## Syntax highlighting

The highlighter is the TextMate grammar in
`syntaxes/y.tmLanguage.json`, contributed by `package.json` as the `source.y`
scope. It is deliberately **not** the server's job: the grammar keeps working
when `yserve` is stopped, and the LSP advertises no semantic-token capability.

The grammar's patterns are ordered so strings win over comments (`#strings`
precedes `#comments`), because TextMate takes the match that starts earliest. It
also gives the language's own names their own scopes: `def` names and calls are
`entity.name.function.y`, `type`, `str`, `long`, `float` and friends are
`support.type.y`, and the predeclared builtins are `support.function.builtin.y`.
The theme decides how those scopes look, exactly as it does for any other
language.

`client-check.js` asserts the grammar is contributed, that the file is valid
JSON with `scopeName: source.y`, and that `#strings` still precedes `#comments`.
## Settings

| Setting | Default | What it does |
|---|---|---|
| `y.lsp.serverPath` | `""` | The `yserve` binary. Empty means search as above. |
| `y.lsp.rootPath` | `""` | Passed as `--root`. Imports in an open file resolve against **that file's own directory** first, so this only matters for files outside the workspace. Empty uses the first workspace folder. |
| `y.lsp.checkOnChange` | `true` | Run the checker and the linter on every keystroke. Off checks on open and on save only, which is much cheaper on a large file and costs you live errors. **The other features are unaffected** — hover, completion and Format Document read your unsaved buffer, and the TextMate grammar never waits for a check. |
| `y.lsp.warnings` | `false` | Passes `-W` to `yserve`, adding the dropped-value and empty-`else` checks. Off is `yserve`'s own default and is **less** than `ycc`, which warns by default — turn this on if you want the editor to agree with the compiler. |
| `y.lsp.trace.server` | `"off"` | `messages` or `verbose` logs the JSON-RPC traffic to the **Y** output channel. |

Every setting in that table is read by the client and every setting the client
reads is in that table — `activation-check.js` asserts both directions, because a
setting that appears in the UI and does nothing is the quietest kind of broken:
the user changes it, sees no difference, and concludes the feature is unreliable.

## Commands

- **Y: Restart Language Server** — also on the status bar item.
- **Y: Show Server Output** — the **Y** output channel. This is where the
  server's own messages go, including a compiler message the user otherwise
  never sees.

## Install (user level)

```sh
code --install-extension src/tools/lsp/vscode-y-lang/y-lang-0.2.0.vsix
```

Then reload VS Code. `.y` files are handled automatically.

To develop it, open `src/tools/lsp/vscode-y-lang` in VS Code and press <kbd>F5</kbd>
— that launches an Extension Development Host with the extension loaded from
source.

## Build

```sh
cd src/tools/lsp/vscode-y-lang
npm ci            # or npm install
npm run compile   # tsc -> out/
```

From the repository root, `make lsp-ext` does both and `make lsp-vsix` packages
the `.vsix`.

`vscode-languageclient` is in `dependencies`, not `devDependencies`, and
`.vscodeignore` does not list `node_modules`. Both matter: together they are what
makes `vsce` bundle the runtime dependency into the package. Get either wrong and
you get a 10 KB `.vsix` that fails on activation with a module-not-found — which
is why `src/tools/lsp/test/activation-check.js` asserts on the manifest before it
loads anything.

## Files

- `package.json` — the manifest: `main`, `onLanguage:y`, the language, the three
  settings.
- `src/extension.ts` — activation: find the server, start it, report its death,
  and gate the not-yet-implemented features on what the server advertises.
- `src/client.ts` — where to find `yserve`, and the argument list. Pure logic,
  so it can be tested without spawning anything.
- `language-configuration.json` — comments, brackets, auto-close, indentation.
- `syntaxes/y.tmLanguage.json` — the TextMate grammar, contributed in `package.json` as the `source.y` scope.
- `tsconfig.json` — strict, `commonjs`, `out/`.

## Tests

Both need `npm ci` first, and both run from the repository root:

```sh
make lsp-e2e
```

- `src/tools/lsp/test/activation-check.js` — runs `activate()` against a stub of
  the `vscode` module and asserts that the extension registers its commands,
  spawns the server, reaches `Running`, and says something useful when it cannot
  start. The stub answers unknown names with a *class*, so a call the library
  makes on something unmodelled fails loudly instead of returning `undefined`.
- `src/tools/lsp/test/client-check.js` — drives `yserve` with `vscode-jsonrpc`,
  the JSON-RPC library VS Code itself uses, through the exact message sequence an
  editor sends. This is what proved the server agrees with a real LSP
  implementation rather than only with the hand-written driver in `ytest lsp-e2e`.
  It **behaves like the editor**: when the server advertises the
  pull-diagnostics capability it pulls, because a server that claims pull and
  answers only push makes VS Code ignore the push notifications and show no
  diagnostics at all — which is what happened, and what this driver now catches.
- `ytest check-names` — no two path-imported modules may define the
  same name. A Y path import *flattens* into the caller's namespace, so a shared
  name is either a duplicate-definition error pointing at the wrong file or one
  definition silently shadowing the other.
