// print(f) used to build its six places by double arithmetic -- int part by
// cvttsd2si, fraction times 1e6, plus 0.5, truncate -- which is round-half-up
// and loses whatever the 53-bit product could not carry. So print(x) and
// f"{x:.6f}" disagreed on a tie (the f-string path rounds half to even, as
// C's printf does) and neither always matched C:
//
//     print(3123845.1640625)      # was 3123845.164063, C says 3123845.164062
//     print(0.0000025)            # was 0.000002,    C says 0.000003
//     print(-0.0)                 # was 0.000000,    C says -0.000000
//     print(1e300)                # was <float magnitude >2^63>
//
// The runtime now hands the float's bits to std/str.y's y_fmt_f, which writes
// the exact binary value out in decimal and rounds half to even -- the same
// code the f-string path uses, so the two cannot drift apart again.

// exact ties: half to even, on both sides of the sign
print(3123845.1640625);
print(0.0000005);
print(0.0000015);
print(0.0000025);
print(0.0000035);
print(1.0000005);
print(0.9999995);
print(-0.0000005);
print(2.5, " ", 3.5, " ", -2.5, " ", -3.5);
print(0.125, " ", 0.375, " ", 0.625, " ", 0.875);

// and print agrees with the f-string for the same value
print(f"{3123845.1640625}");
print(f"{0.0000025}");
print(f"{0.0000035}");
print(f"{-2.5}");
print(tostring(3123845.1640625));
print(tostring(-2.5));

// the sign of a zero, which `x < 0` never sees
print(-0.0);
print(0.0);
print(f"{-0.0}");

// ordinary values, and the rounding that is not a tie
print(0.1, " ", 1.0 / 3.0, " ", -1.0 / 3.0, " ", 3.14159265358979);
print(1e-7, " ", 0.5, " ", -1.5, " ", 1e19, " ", 123456789012345678.0);

// a magnitude past 2^63 is printed exactly now, not refused
print(1e300);
print(-1e300);
// and the specials read as themselves
print(1.0 / 0.0, " ", -1.0 / 0.0, " ", 0.0 / 0.0);