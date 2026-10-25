// flags: --gc=never
def append(a: [long]) -> [long] { a += 7 }
def make() -> [long] { let a: [long] = []; append(a) }
def assign() -> [long] { let a: [long] = []; a = a + [8] }
def field() -> [long] { let a = { value: [0] }; a.value = [9] }
def element() -> [long] { let a: [[long]] = [[]]; a[0] = [10] }
let kept = make();
let assigned = assign();
let stored_field = field();
let stored_element = element();
let total = 0;
for i in 0..100 { let scratch = [i; 100]; total += scratch[0]; }
print(total);
print(kept[0]);
print(assigned[0]);
print(stored_field[0]);
print(stored_element[0]);
