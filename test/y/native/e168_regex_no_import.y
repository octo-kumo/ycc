// expect-error: 7:17: error: undefined function 'compile'
// expect-error: 8:18: error: cannot call <error> (not a function)
// expect-error: 9:13: error: undefined function 'escape'
// std/regex.y is a module: without `import regex;` there is no compile, and
// re.match(s) is a field of the record — there are no closures, so a Re cannot
// carry its own methods.
let re = compile("a+b");
print(re.is_match("aab"));
print(escape("a.b"));