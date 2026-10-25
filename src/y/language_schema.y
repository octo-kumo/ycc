// Shared compiler/editor vocabulary. Contextual words remain identifier tokens.
const RESERVED_WORDS = ["let", "const", "def", "ndef", "if", "else", "while", "for", "foreach", "in", "return", "true", "false", "break", "continue"];
const CONTEXTUAL_WORDS = ["match", "type", "spawn", "fork", "lock", "try_lock", "join", "post", "wait", "mutex", "sem", "self", "none", "import", "export", "embed", "from", "region", "heap", "packed", "bits"];

type StringMethodSpec = { names: str, fn: str, params: [str], required: long, result: str, default: str, last: bool };
const STRING_METHODS: [StringMethodSpec] = [
    { names: "split", fn: "split", params: ["str"], required: 1, result: "[str]", default: "", last: false },
    { names: "join", fn: "join", params: ["[T]"], required: 1, result: "str", default: "", last: true },
    { names: "trim strip", fn: "trim", params: [], required: 0, result: "str", default: "", last: false },
    { names: "trim_start lstrip", fn: "y_str_trim_start", params: [], required: 0, result: "str", default: "", last: false },
    { names: "trim_end rstrip", fn: "y_str_trim_end", params: [], required: 0, result: "str", default: "", last: false },
    { names: "pad_left", fn: "y_str_pad_left", params: ["long", "str"], required: 1, result: "str", default: " ", last: false },
    { names: "pad_right", fn: "y_str_pad_right", params: ["long", "str"], required: 1, result: "str", default: " ", last: false },
    { names: "center", fn: "y_str_center", params: ["long", "str"], required: 1, result: "str", default: " ", last: false },
    { names: "starts_with", fn: "y_str_starts_with", params: ["str"], required: 1, result: "bool", default: "", last: false },
    { names: "ends_with", fn: "y_str_ends_with", params: ["str"], required: 1, result: "bool", default: "", last: false },
    { names: "contains", fn: "y_str_contains", params: ["str"], required: 1, result: "bool", default: "", last: false },
    { names: "index_of", fn: "index_of", params: ["str", "long"], required: 1, result: "long", default: "0", last: false },
    { names: "last_index_of", fn: "last_index_of", params: ["str", "long"], required: 1, result: "long", default: "9223372036854775807", last: false },
    { names: "count", fn: "y_str_count", params: ["str"], required: 1, result: "long", default: "", last: false },
    { names: "replace", fn: "y_str_replace", params: ["str", "str"], required: 2, result: "str", default: "", last: false },
    { names: "upper", fn: "y_str_upper", params: [], required: 0, result: "str", default: "", last: false },
    { names: "lower", fn: "y_str_lower", params: [], required: 0, result: "str", default: "", last: false },
    { names: "repeat", fn: "y_str_repeat", params: ["long"], required: 1, result: "str", default: "", last: false },
    { names: "lines", fn: "y_str_lines", params: [], required: 0, result: "[str]", default: "", last: false },
    { names: "bytes", fn: "bytes", params: [], required: 0, result: "[byte]", default: "", last: false },
    { names: "tolong", fn: "tolong", params: [], required: 0, result: "long?", default: "", last: false },
    { names: "tofloat", fn: "tofloat", params: [], required: 0, result: "float?", default: "", last: false },
    { names: "ord", fn: "ord", params: [], required: 0, result: "long", default: "", last: false },
    { names: "byte_at", fn: "byte_at", params: ["long"], required: 1, result: "long", default: "", last: false },
];
const INTRINSICS: [str] = ["print", "syscall", "len", "sizeof", "offsetof", "push", "some", "is_some", "unwrap",
    "opt$test", "opt$val", "region$", "region$auto", "heap$", "values",
    "map$keys", "map$vals", "map$boxes", "map$zidx", "map$find", "map$note",
    "trim", "ord", "byte_at", "chr", "tolong", "tofloat", "tostring", "index_of",
    "mod",
    "prepend",
    "last_index_of", "join", "split", "puts", "eputs", "clock_us",
    "time_us", "sleep", "heap_used", "keys", "spawn", "fork", "wait_pid",
    "mutex", "sem", "lock", "try_lock", "post", "wait", "exit", "argv", "range", "typeof", "bytes",
    "from_bytes", "ptr_addr", "ptr_from", "os_call", "jmp_at", "self", "none", "#fmt"];

export { INTRINSICS, RESERVED_WORDS, CONTEXTUAL_WORDS, STRING_METHODS, StringMethodSpec };
