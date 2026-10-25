// W8/S10 in the page: web.fetch of a sibling file, the query parameter,
// eval and open_url. The driver navigates with ?tag=tag-value and serves
// w113_data.txt beside the module; a 404 is none.
import web;

def onoff(b: bool) -> str { if (b) { "true" } else { "false" } };

puts("platform " + web.platform() + "\n");
let p = web.param("tag");
puts("param " + (if (p == none) { "none" } else { p! }) + "\n");
let e = web.eval("6 * 7");
puts("eval " + (if (e == none) { "none" } else { e! }) + "\n");
let b = web.fetch("w113_data.txt");
puts("fetch " + (if (b == none) { "none" } else { from_bytes(b!) }));
puts("fetchlen " + (if (b == none) { "none" } else { tostring(b!.length) }) + "\n");
let m = web.fetch("w113_missing.txt");
puts("missing " + (if (m == none) { "none" } else { "some" }) + "\n");
puts("open " + onoff(web.open_url("about:blank")) + "\n");
puts("done\n");
