def main(argv: [str]) -> long {
    print("in main");
    0
};

let result = main(["ycc", "--emit-c", "/tmp/test.c", "/tmp/test.y"]);
print("result = " + tostring(result));
