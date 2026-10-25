// W4/S8: preemption.  A long loop with a small fuel budget leaves the chunk
// at its back edge, the host resumes it at the token it was given, and the
// result is the same as a run with no preemption at all.  Run with
// --fuel=300 (see w006_preempt.runflags) so the loop is cut thousands of
// times.
let i = 0;
let sum = 0;
while (i < 200000) { sum = sum + i; i = i + 1; };
print(sum, "\n");
let j = 0;
let acc = 0;
while (j < 50000) { acc = acc * 3 + j; j = j + 1; };
print(acc, "\n");
