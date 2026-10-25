// Every float comparison used to read NaN as ordered. ucomisd leaves
// ZF=PF=CF=1 when the operands are unordered, and the parity flag was never
// read, so `<`, `<=`, `==` and `!=` all said yes to a NaN:
//
//     z = 0.0/0.0;   z < 1.0   was true      (false)
//                     z <= 1.0  was true      (false)
//                     z == z    was true      (false)
//                     z != z    was false     (true)
//
// `>` and `>=` were right by accident (seta/setae test CF, which unordered
// sets). The array element path shares the compare, so `[nan] == [1.0]` was
// true and two arrays of different floats compared equal -- which is what any
// dedup, cache or set-like membership over [float] would have been silently
// built on. Records and maps compare by identity, so nothing leaks in there.

let nan = 0.0 / 0.0;
let inf = 1.0 / 0.0;
let ninf = -1.0 / 0.0;

// all six, both operand orders
print(nan < 1.0, " ", nan <= 1.0, " ", nan > 1.0, " ", nan >= 1.0, " ", nan == nan, " ", nan != nan);
print(1.0 < nan, " ", 1.0 <= nan, " ", 1.0 > nan, " ", 1.0 >= nan, " ", nan == 1.0, " ", nan != 1.0);

// against infinity, both signs
print(nan < inf, " ", nan <= inf, " ", nan > inf, " ", nan >= inf, " ", nan == inf, " ", nan != inf);
print(inf < nan, " ", inf <= nan, " ", inf > nan, " ", inf >= nan, " ", inf == nan, " ", inf != nan);
print(ninf < nan, " ", ninf <= nan, " ", ninf > nan, " ", ninf >= nan, " ", ninf == nan, " ", ninf != nan);

// infinity and signed zero are unaffected
print(inf == inf, " ", inf <= inf, " ", inf < 1.0e308, " ", inf > 1.0e308, " ", inf >= 1.0e308, " ", inf != inf);
print(ninf < 0.0, " ", ninf <= -1.0e308, " ", 0.0 == -0.0, " ", -0.0 != 0.0, " ", 0.0 < -0.0, " ", -0.0 >= 0.0);

// the element compare behind [float] == [float]
print([nan] == [1.0], " ", [nan] != [1.0], " ", [nan] == [nan], " ", [1.0] == [2.0]);
print([1.0, 2.0] == [1.0, 2.0], " ", [1.0, 2.0] == [1.0, 2.0, 3.0]);
print([nan] == [1.0, 2.0], " ", [1.0, nan] == [1.0, 2.0], " ", [1.0, 2.0] != [1.0, nan]);
print([nan, nan] == [nan, nan], " ", [nan] == [nan, 1.0]);

// an option carrying a float compares its payload
let o1: float? = none;
let o2: float? = some(nan);
let o3: float? = some(1.0);
print(o1 == none, " ", o2 == o3, " ", o2 != o3, " ", some(nan) == some(nan), " ", some(1.0) == some(1.0));

// records and maps are compared by identity, so a NaN field changes nothing
let r1 = { v: nan };
let r2 = { v: nan };
print(r1 == r1, " ", r1 == r2);
let m1 = { "k": nan };
let m2 = { "k": nan };
print(m1 == m1, " ", m1 == m2);

// and in a loop, where a NaN used to end an equality test early
let hits = 0;
let vals = [1.0, 2.0, 3.0];
foreach (v in vals) {
    if (v == nan) { hits = hits + 1; };
};
print(hits);
