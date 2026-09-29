// The pure parts of the net module: response building, address packing.
import net;

let r = net.http_response(200, "hello");
print(len(r));
print(substr(r, 0, 15));
print(substr(r, len(r) - 5, 5));
let r404 = net.http_response(404, "x");
print(substr(r404, 0, 22));

let a: [byte; 16] = [0; 16];
net.addr_set(a, "127.0.0.1", 8080);
print(a[0]);
print(a[2]);
print(a[3]);
print(a[4]);
print(a[7]);
exit(0);
