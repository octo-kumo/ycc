// TODO.y: [[long]] + [[long]] is a new outer array that shares the rows --
// a row written through one is seen through the other, but growing one
// outer array leaves the other alone. Arrays nest in literals too.
let arr_of_arr:[[long]] = [[1, 2], [3, 4], [5, 6]];
let second_aarr: [[long]] = [[7, 8], [9, 10]];
let comb = arr_of_arr + second_aarr;
print(comb);
arr_of_arr[0][0] = 100;
print(comb);
arr_of_arr += [[11, 12]];
print(comb);
print(arr_of_arr);
let comb3 = [arr_of_arr, second_aarr];
print(comb3);
