// W8/S10: std/web off the web. y_os_host_sym answers 0, so every function
// says "not available" -- false, "", 0 or none -- and no host call is made.
// (The Node host does have web.*: w040_web_api is that side, and this fixture
// carries a .skip.web for the corpus run through it.)
import web;

puts("available " + (if (web.available()) { "true" } else { "false" }) + "\n");
puts("platform [" + web.platform() + "]\n");
puts("sym " + tostring(web.sym("web.platform")) + "\n");
puts("call " + tostring(web.call(web.sym("web.platform"), [1, 2])) + "\n");
let s = web.call_str(web.sym("web.platform"), []);
puts("call_str " + (if (s == none) { "none" } else { s! }) + "\n");
let e = web.eval("1 + 1");
puts("eval " + (if (e == none) { "none" } else { e! }) + "\n");
let p = web.param("name");
puts("param " + (if (p == none) { "none" } else { p! }) + "\n");
puts("open " + (if (web.open_url("https://example.com/")) { "true" } else { "false" }) + "\n");
let f = web.fetch("file:///etc/hostname");
puts("fetch " + (if (f == none) { "none" } else { "some" }) + "\n");
web.log("never printed");
puts("log done\n");
