// expect-error: 12:9: error: tostring takes exactly 1 argument
// expect-error: 13:7: error: typeof takes exactly 1 argument
// expect-error: 14:9: error: index_of takes exactly 2 arguments (string, sub)
// expect-error: 15:14: error: last_index_of takes exactly 2 arguments (string, sub)
// expect-error: 16:5: error: join takes exactly 2 arguments (array, delimiter)
// expect-error: 17:6: error: split takes exactly 2 arguments (string, delimiter)
// expect-error: 18:6: error: range takes exactly 1 argument
// expect-error: 19:6: error: eputs takes exactly 1 argument
// expect-error: 20:9: error: clock_us takes no arguments
// expect-error: 21:10: error: heap_used takes no arguments
// expect-error: 22:6: error: sleep takes exactly 1 argument (milliseconds)
tostring();
typeof();
index_of("");
last_index_of("");
join();
split();
range();
eputs();
clock_us(1);
heap_used(1);
sleep();
time_us(1);
// expect-error: 23:8: error: time_us takes no arguments
keys();
keys(5);
// expect-error: 25:5: error: keys takes exactly 1 argument
// expect-error: 26:5: error: keys needs a map, got long
