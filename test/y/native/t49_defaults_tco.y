// default parameter values and tail calls through the function's own name
def factorial(n: long, acc = 1) {
    if (n <= 1) {
        return acc;
    }
    return factorial(n - 1, n * acc);
}
print(factorial(20));
print(factorial(5, 2));

// a million-deep self call runs in constant stack
def count(n: long, acc: long) -> long {
    if (n == 0) { acc } else { count(n - 1, acc + 1) }
}
print(count(3000000, 0));

def greet(name: str, greeting = "hello", punct: str = "!") -> str {
    greeting + ", " + name + punct
}
print(greet("y"));
print(greet("y", "hi"));
print(greet("y", "hi", "?"));

def scale(x: float, k = 2.5) -> float { x * k }
print(scale(2.0));

def neg(x: long, d = -3) -> long { x + d }
print(neg(10));

def flag(b = false, c = 'z') { print(b, " ", c) }
flag();
