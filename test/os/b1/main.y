// b1 -- the proc/fd tests in one program: `b1 pipe|fd|sig|poll|exec`.  `b1 child ...`
// is what `b1 exec` starts.
import t_pipe from "./pipe.y";
import t_fd from "./fd.y";
import t_sig from "./sig.y";
import t_poll from "./poll.y";
import t_exec from "./exec.y";
import t_child from "./child.y";

let av = argv();
let which = "";
if (len(av) >= 2) { which = av[1]; };
if (which == "pipe") { t_pipe.run_pipe(); }
else if (which == "fd") { t_fd.run_fd(); }
else if (which == "sig") { t_sig.run_sig(); }
else if (which == "poll") { t_poll.run_poll(); }
else if (which == "exec") { t_exec.run_exec(); }
else if (which == "child") { t_child.run_child(); }
else { puts("usage: b1 pipe|fd|sig|poll|exec\n"); };
