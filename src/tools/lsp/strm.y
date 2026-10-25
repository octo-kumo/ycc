// String hover/completion entries are compiled from the compiler's method schema.

import helpdata from "./string_help.y";

def method_help(name: str) -> StringHelp? {
    foreach (entry in STRING_HELP) { if (entry.name == name) { return some(entry); }; };
    none
}

def is_method(name: str) -> bool { is_some(method_help(name)) }
def names() -> [str] { STRING_HELP.map(entry => entry.name) }
def sig(name: str) -> str {
    if let some(entry) = method_help(name) { entry.signature } else { name + "(?) -> ?" }
}
def matching(prefix: str) -> [str] { names().filter(name => name.starts_with(prefix)) }

export { method_help, is_method, names, sig, matching };
