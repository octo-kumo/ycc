// trunc, ceil and round answer a ZERO for an argument in (-1, 0) and (-0.5, 0),
// and C gives that zero the argument's sign: trunc(-0.5), ceil(-0.5) and
// round(-0.4) are -0.0. The module answered +0.0 for all three -- the cast to a
// long answers 0, which has no sign to keep -- and its own comment promised C.
// The table's reference had the same defect (Python's int() has no -0), so it
// certified the module; `ytest math-table` against a correctly rounded reference
// found 126 rows. 1.0 / the answer is what tells the two zeros apart.
import math;

def show(name: str, v: float) {
    print(name, " = ", v, ", 1/it = ", 1.0 / v);
};

show("trunc(-0.5)", math.trunc(-0.5));
show("trunc(-0.999)", math.trunc(-0.999));
show("ceil(-0.5)", math.ceil(-0.5));
show("ceil(-1e-300)", math.ceil(-1e-300));
show("round(-0.4)", math.round(-0.4));
show("round(-1e-300)", math.round(-1e-300));
show("fract(-0.5)", math.fract(-0.5));
// the positive side and the zeros themselves are unchanged
show("trunc(0.5)", math.trunc(0.5));
show("ceil(0.5)", math.ceil(0.5));
show("round(0.4)", math.round(0.4));
show("floor(-0.5)", math.floor(-0.5));
show("trunc(-0.0)", math.trunc(0.0 * -1.0));
show("ceil(-0.0)", math.ceil(0.0 * -1.0));
// and the integers still come back as themselves
show("trunc(-2.5)", math.trunc(-2.5));
show("ceil(-2.5)", math.ceil(-2.5));
show("round(-2.5)", math.round(-2.5));
