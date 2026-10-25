let r = {n: 1};
let alias = r;
let copy = {n: r.n};
print(r == alias);
print(r == copy);
alias.n = 2;
print(r.n);

let m = {"k": 1};
let m_alias = m;
let m_copy = {"k": 1};
print(m == m_alias);
print(m == m_copy);

let a = [1, 2];
let equal = [1, 2];
print(a == equal);
let maybe: [long]? = some(a);
maybe![0] = 9;
print(a[0]);

let s = "a";
let s_alias = s;
s += "b";
print(s_alias);
print(s);
