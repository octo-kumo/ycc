// fs.getenv(name): the value of an environment variable from the process's
// start-up environment (/proc/self/environ), or none. Names match whole: a
// prefix of a variable's name, or the empty name, is not it.
import fs;
print(fs.getenv("YCC_NO_SUCH_VARIABLE_Q"));
print(fs.getenv("PAT"));
print(fs.getenv(""));
let any = fs.getenv("PATH") != none || fs.getenv("HOME") != none || fs.getenv("PWD") != none;
print(any);
let p = fs.getenv("PATH");
if let str v = p { print(len(v) > 0); } else { print(true); };
