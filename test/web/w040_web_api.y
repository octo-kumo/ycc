// W8/S10: std/web under the Node host. platform is "node"; param is none;
// eval runs the script in the host; fetch reads a file:// URL and a path
// relative to the working directory; log goes to the program's stdout. The
// native fixture t462_web_stub.y is the other half: off the web every one of
// these answers "not available".
import web;
import fs;

def onoff(b: bool) -> str { if (b) { "true" } else { "false" } };

puts("available " + onoff(web.available()) + "\n");
puts("platform " + web.platform() + "\n");
puts("sym " + onoff(web.sym("web.platform") > 0) + "\n");
puts("nosym " + tostring(web.sym("no.such.function")) + "\n");
puts("call0 " + tostring(web.call(0, [])) + "\n");

// The public retry API, then one raw call with its own (buf, cap).
let cs = web.call_str(web.sym("web.platform"), []);
puts("call_str " + (if (cs == none) { "none" } else { cs! }) + "\n");
let buf: [byte] = [];
let i = 0;
while (i < 16) { buf += 0; i = i + 1; };
let n = web.call(web.sym("web.platform"), [ptr_addr(&buf[0]), 16]);
puts("call " + (if (n < 0) { "none" } else { from_bytes(buf[0:n]) }) + "\n");

let p = web.param("name");
puts("param " + (if (p == none) { "none" } else { p! }) + "\n");
let e = web.eval("1 + 1");
puts("eval " + (if (e == none) { "none" } else { e! }) + "\n");
let eb = web.eval("return 'a' + 'b'");
puts("evalbody " + (if (eb == none) { "none" } else { eb! }) + "\n");
let et = web.eval("throw new Error('no')");
puts("evalthrow " + (if (et == none) { "none" } else { "some" }) + "\n");

web.log("log line");
let f = web.fetch("file://" + fs.cwd() + "/test/web/w040_data.txt");
puts("file " + (if (f == none) { "none" } else { from_bytes(f!) }));
let r = web.fetch("test/web/w040_data.txt");
puts("relative " + (if (r == none) { "none" } else { from_bytes(r!) }));
let m = web.fetch("test/web/w040_missing.txt");
puts("missing " + (if (m == none) { "none" } else { "some" }) + "\n");
puts("open " + onoff(web.open_url("https://example.com/")) + "\n");
