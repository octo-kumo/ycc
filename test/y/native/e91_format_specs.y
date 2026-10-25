// expect-error: 14:9: error: format spec '.': '.' without a precision
// expect-error: 15:9: error: format spec '??': cannot read '??'
// expect-error: 16:9: error: format spec '100000': width and precision stop at 99999
// expect-error: 17:9: error: format spec 'd': type 'd' needs a number, not bool
// expect-error: 18:9: error: format spec '+': a sign needs a number, not bool
// expect-error: 19:9: error: format spec '#': '#' needs a number, not str
// expect-error: 20:9: error: format spec ',': ',' needs a number, not str
// expect-error: 21:9: error: format spec '=': '=' alignment needs a number, not str
// expect-error: 22:9: error: format spec 's': type 's' needs a string, not long
// expect-error: 23:9: error: format spec '.2': a precision needs a float type (f, e or %), not an integer one
// expect-error: 24:9: error: format spec '+c': type 'c' takes no sign, '#' or grouping
// expect-error: 25:9: error: format spec ',x': ',' does not group type 'x' (use '_')
let text = "x";
print(f"{1:.}");
print(f"{1:??}");
print(f"{1:100000}");
print(f"{true:d}");
print(f"{true:+}");
print(f"{text:#}");
print(f"{text:,}");
print(f"{text:=}");
print(f"{1:s}");
print(f"{1:.2}");
print(f"{1:+c}");
print(f"{1:,x}");
