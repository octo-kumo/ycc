# Y Language Support (VS Code)

Syntax highlighting for the Y programming language (the `ycc` / `ysh`
language in this repo).

Covers:

- declarations and control flow: `let`, `const`, `def`, `type`, `match`,
  `if`/`else`, `while`, `for` (both forms), `foreach`, `in`, `return`;
- modules: `import`, `from`, `embed`, `export`;
- types: `str`, `long`, `int`, `bool`, `float`, `byte`, `void`, `mutex`,
  `sem`;
- the predeclared builtins — `print`, `puts`, `eputs`, `tostring`,
  `tonum`, `typeof`, `range`, `keys`, `len`, `trim`, `split`, `join`,
  `ord`, `chr`, `byte_at`, `index_of`, `last_index_of`, `bytes`,
  `from_bytes`, `some`, `is_some`, `unwrap`, `argv`, `exit`, `readline`,
  `clear_eof`, `clock_us`, `time_us`, `heap_used`, `sleep`, `ptr_addr`,
  `syscall`, and the thread/process words `spawn`, `fork`, `mutex`, `sem`,
  `lock`, `try_lock`, `post`, `wait`, `wait_pid`;
- `self`, `true`, `false`, `none`;
- every string form: `"..."`, `b"..."`, `b'...'`, `f"..."` (f-strings),
  `c'a'`, with the Y escapes (`\n`, `\t`, `\x41`, `\{`, and a backslash
  before any other byte);
- numbers: decimal, `0x`/`0X` hexadecimal, `0b`/`0B` binary, `_` digit
  grouping, floats with a point and/or an exponent;
- the whole operator set, longest match first: `>>>=`, `<<=`, `>>=`,
  `>>>`, `&&`, `||`, `==`, `!=`, `<=`, `>=`, `::`, `..`, `->`, `=>`,
  `?.`, `++`, `--`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`,
  `<<`, `>>` and the single characters;
- comments: `//` to end of line and non-nesting `/* ... */`.

Not builtins, so not highlighted as such: `exec` (needs `import exec;`)
and the file functions (`fs.read_file`, `fs.write_file`,
`fs.write_bytes` — `import fs;`). There is no `substr`; slice with
`s[lo:hi]`.

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

## Note

This TextMate grammar is the highlighting that ships today. The design in
`LSP.md` (at the repository root) retires it: semantic tokens from the
language server become the only highlighter (R2.1, milestone M2), and
this grammar is then unregistered from `contributes` — the file stays in
the tree, so re-enabling it is a one-line revert. Until that lands, the
grammar is the highlighter, and it is kept in step with the language by
hand.
