// expect-error: 11:5: error: '++' needs a number target, got bool
// expect-error: 13:9: error: '*=' element: expected long, got str
// expect-error: 15:8: error: '+=' element: expected long, got str
// expect-error: 17:8: error: arrays support only '+=' and '*=' (in place), not '-='
// expect-error: 19:8: error: '+=' string: expected str, got long
// expect-error: 21:11: error: strings support only '+=' (concatenate), not '*='
// expect-error: 23:8: error: '+=' value: expected long, got str
// expect-error: 25:8: error: '*=' needs a number, string or array target, got { value: long }
// expect-error: 27:7: error: cannot grow fixed array [long; 2] with '*=' (its length is part of its type; use [T] instead)
let flag = true;
flag++;
let prepend: [long] = [];
prepend *= "bad";
let append: [long] = [];
append += "bad";
let remove: [long] = [];
remove -= 1;
let concat = "";
concat += 1;
let no_repeat = "";
no_repeat *= 1;
let number = 1;
number += "bad";
let record = { value: 1 };
record *= 1;
let fixed: [long; 2] = [0; 2];
fixed *= 1;
