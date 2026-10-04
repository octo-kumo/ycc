# Y Language Support (VS Code)

Syntax highlighting for the Y programming language (the ycc / ysh language in this repo).

Covers: `let`/`const`/`def`, control flow, types (`str`, `long`, `bool`, `float`),
builtins (`print`, `puts`, `eputs`, `exec`, `readline`, `clear_eof`, `len`, ...),
strings with Y escape sequences (`\n`, `\x41`), numbers, comments, and
operators (`::`, `..`, `->`).

## Install (user level)

```sh
code --install-extension y-lang-0.1.0.vsix
```

Then reload VS Code. `.y` files will be highlighted automatically.

## Rebuild the .vsix

```sh
npx -y @vscode/vsce package --allow-missing-repository && code --install-extension y-lang-0.1.0.vsix
```

## Files

- `package.json` — extension manifest (contributes the `y` language + grammar)
- `language-configuration.json` — comment/bracket/auto-close behavior
- `syntaxes/y.tmLanguage.json` — TextMate grammar
