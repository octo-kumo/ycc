// none is the empty option; x! unwraps (like unwrap(x)); void is "no value".
let a: long? = none;
let b: long? = some(41);
print(a);
print(b);
print(a == none);
print(b == none);
print(b! + 1);
print(unwrap(b) == b!);
print(typeof(none));
print(typeof(b));
print(tostring(a));

// ! is postfix: it binds tighter than unary !
let f: bool? = some(false);
print(!f!);

// an option of a record, unwrapped then read
let r: {x: long}? = some({x: 7});
print(r!.x);

// disagreeing if arms make a void statement -- legal on its own
if (b! > 0) { 1 } else { "neg" };

// a def with a bare return is void; -> void discards the tail
def log(msg: str) {
    if (len(msg) == 0) { return; };
    print("log: " + msg);
};
log("");
log("hello");
def noisy(x: long) -> void { print(x); x * 100 };
noisy(3);