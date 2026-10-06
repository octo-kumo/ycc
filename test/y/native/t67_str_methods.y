// String methods: `s.m(args)` on any str value (types.y str_method).
let s = "  Hello, World  ";
print("[" + s.trim() + "]");
print("[" + s.strip() + "]");
print("[" + s.trim_start() + "]");
print("[" + s.lstrip() + "]");
print("[" + s.trim_end() + "]");
print("[" + s.rstrip() + "]");
print("str 1 2 3".split(" "));
print("a,b,,c".split(","));
print(", ".join(["x", "y", "z"]));
print("-".join([1, 2, 3]));
print("7".pad_left(3, "0"));
print("[" + "ab".pad_left(5) + "]");
print("[" + "ab".pad_right(5) + "]");
print("ab".pad_right(7, "-="));
print("abc".pad_left(2));
print("[" + "ab".center(7, "*") + "]");
print("[" + "ab".center(6) + "]");
print("hello".starts_with("he"), " ", "hello".starts_with("lo"), " ", "hello".starts_with(""));
print("hello".ends_with("lo"), " ", "hello".ends_with("he"), " ", "lo".ends_with("hello"));
print("hello".contains("ell"), " ", "hello".contains("xyz"), " ", "hello".contains(""));
print("hello".index_of("l"), " ", "hello".last_index_of("l"), " ", "hello".index_of("z"));
print("banana".count("an"), " ", "aaaa".count("aa"), " ", "abc".count(""));
print("a-b-c".replace("-", "+"), " ", "aaa".replace("a", "bb"), " ", "abc".replace("", "x"), " ", "abc".replace("z", "y"));
print("Hello, World 123".upper(), " ", "Hello, World 123".lower());
print("ab".repeat(3), "|", "x".repeat(0), "|", "y".repeat(0 - 2), "|");
print("one\ntwo\r\nthree\n".lines());
print(len("".lines()), " ", len("\n".lines()), " ", len("a\n\nb".lines()), " ", len("a\nb".lines()));
print("42".tolong()! + 1, " ", "A".ord(), " ", "AB".byte_at(1));
print(len("hi".bytes()));
// chains, and methods on any str-valued expression
print("  a,b ,c  ".trim().split(",")[1].trim().upper());
let words = ["alpha", "beta"];
print(words[0].upper() + words[1].pad_left(6, "."));
def shout(x: str) -> str { x.upper() + "!" };
print(shout("hey").repeat(2));
print("a b c".split(" ").length);
foreach (w in "x=1;y=22".split(";")) {
    let kv = w.split("=");
    print(kv[0].upper() + ": " + kv[1].pad_left(3, "0"));
};
// method names are not reserved: a def, a local and a record field may
// use them, and a field holding a function is still a plain call
def upper(n: long) -> long { n + 1 };
let count = 3;
print(upper(count), " ", "abcabc".count("bc"));
let obj = { upper: def(x: long) -> long { x * 2 } };
print(obj.upper(21));
