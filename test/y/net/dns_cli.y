// The resolver against test/y/net/dns_srv.y on port argv[1] (src/tools/ytest/su_net.y):
// a CNAME and two A records, a truncated answer retried over TCP, NXDOMAIN,
// a malformed answer, a label too long to ask for; then names that need
// no server: a dotted quad and /etc/hosts.
import net;

let port = tolong(argv()[1])!;
def ask(name: str) -> [str] { net.resolve_with(name, "127.0.0.1", port) };
print(ask("two.test"));
print(ask("trunc.test"));
print(ask("missing.test"));
print(ask("garbage.test"));
print(ask("x".pad_left(64, "x") + ".test"));
print(net.resolve("10.0.0.1"), " ", net.resolve("localhost"));
