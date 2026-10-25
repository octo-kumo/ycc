// A listener must report a port it could not bind (M22). bind_tcp answers the
// syscall's own result, so a second socket on a busy port gives -98
// (EADDRINUSE); listen_tcp used to ignore it, which left accept blocked on a
// socket bound to nothing -- the program hung with no diagnostic. It prints
// the errno and exits 1.
import net;

let first = net.socket_tcp();
print("first bind: ", net.bind_tcp(first, 18080));
let again = net.socket_tcp();
print("second bind gives ", net.bind_tcp(again, 18080));
net.listen_tcp(18080, def (c: long) -> long { 0 });
print("not reached");

// http's listener checks the same way; unreachable here, but the shape is the
// same two calls.
net.listen_http(18080, def (req: str) -> str { net.http_response(200, "hi") });
print("not reached either");