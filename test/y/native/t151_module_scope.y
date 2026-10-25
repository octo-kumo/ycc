// A module imported by name keeps its own scope: the program reaches its
// names as m151.x, never bare, so it may use the same names itself; the
// module's own code finds its names first; a binding named like the
// module hides it.
import m151;
import fs;

def helper() -> str { "the program's helper" };
let count = 10;
print(helper());
print(m151.helper());
print(m151.count, " ", count);
m151.count = 5;
print(m151.bump(), " ", m151.count);
def twice(x: long) -> long { x * 100 };
print(twice(2), " ", m151.twice(2));
def f() -> long {
    let m151 = { count: 7 };
    m151.count
};
print(f());
// std modules too: fs's names are free for the program
let exists = "mine";
def cwd() -> str { "my cwd" };
print(exists, " ", cwd(), " ", fs.exists("."), " ", fs.cwd().length > 0);
// parameter defaults go with the qualified name
print(m151.greet("ann"), " ", m151.greet("bob", "hi"));
