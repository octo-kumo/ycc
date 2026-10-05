// A module the diagnostics fixture imports, with a warning in it, so the
// "a diagnostic in an imported file is labelled with that file" case has
// something to find. Checked on its own too: it must compile clean of errors.

export { f };

def f() -> long {
    let spare = 1;          // unused: a warning, attributed to this file
    7
}
