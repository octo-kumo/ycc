def classify(x: long) -> str {
    if (x < 0) { "neg" }
    else if (x == 0) { "zero" }
    else { "pos" }
};
export { classify };
