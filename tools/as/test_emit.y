// test_emit.y — exercise the AssemblyScript emitter.
import emit from "./emit_as.y";

let src = "def fib(n: long) -> long {
    if (n < 2) { return n; };
    return self(n - 1) + self(n - 2);
};

def square(x: long) -> long {
    return x * x;
};
";

print(emit.emit(src));
