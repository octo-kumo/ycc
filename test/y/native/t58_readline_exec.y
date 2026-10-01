// readline() buffers stdin, but exec() first gives the unread part back
// (stdin here is a file, so it can seek): each child reads on from the
// line after the last one we returned, and we carry on after whatever the
// child consumed. On a pipe the buffered lines would stay ours instead.
let a = readline();
print("parent: " + a!);
exec("read x; echo \"child: $x\"");
let b = readline();
print("parent: " + b!);
exec("read x; read y; echo \"child: $x $y\"");
let c = readline();
print("parent: " + c!);
let d = readline();
if (d == none) { print("parent: none"); } else { print("parent: unexpected " + d!); };
