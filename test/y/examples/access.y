const map = {
    a: 1,
    b: def(a: long, b: long) {a+b}
};
print(map);
print("map.a = "+map.a);
print("map.b(1,2) = "+ ((map.b)(1,2)) + 1);
