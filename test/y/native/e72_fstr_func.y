// expect-error: 3:9: error: an f-string field takes long/bool/float/str/array/record/map/option, got (long) -> long
def g(x: long) -> long { x };
print(f"{g}");
