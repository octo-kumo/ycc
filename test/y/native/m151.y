// t151's module, imported by name (`import m151;`): its names are its own.
let count = 3;
def twice(x: long) -> long { x * 2 };
def helper() -> str { "module helper " + tostring(twice(21)) };
def bump() -> long {
    count = count + 1;
    count
};
def greet(who: str, word: str = "hello") -> str { word + " " + who };
