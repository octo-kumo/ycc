// flags: -W 2
def f(all: [str]) -> [str] {
    let out: [str] = [];
    all.foreach((e) => {
        let l = e; // expect-warning: 'l' is only another name for the parameter 'e'; rename the parameter
        if (len(l) > 0 && l[0] != 35) { out += l; };
    });
    out
};
def main() -> long { let r = f(["#x", "ab"]); print(r.length); 0 };
exit(main());
