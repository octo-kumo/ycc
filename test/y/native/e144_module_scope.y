// A module imported by name is reached through its name only.
// expect-error: 5:6: error: undefined function 'twice'
// expect-error: 6:12: error: undefined function 'm151.thrice'
import m151;
twice(2);
m151.thrice(2);
