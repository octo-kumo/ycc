// Framing owns its read buffer and preserves exact body bytes.
import rpc from "../rpc.y";

def reader(text: str) -> In { { buf: bytes(text), pos: 0, eof: true } }
let r = reader("cOnTeNt-LeNgTh: 2\r\nX-Other: ignored\r\n\r\néContent-Length: 3\n\nabc");
print("UTF-8 body: " + rpc.read_frame(r, -1)!);
print("next frame: " + rpc.read_frame(r, -1)!);
print("EOF: " + tostring(!is_some(rpc.read_frame(r, -1))));
rpc.in_fill(r, -1);
print("consumed released: " + tostring(len(r.buf) == 0 && r.pos == 0));
let partial = reader("oldNEXT");
partial.pos = 3;
rpc.in_fill(partial, -1);
print("unread retained: " + from_bytes(partial.buf));
print("truncated body: " + rpc.read_frame(reader("Content-Length: 8\r\n\r\nshort"), -1)!);
print("empty stream: " + tostring(!is_some(rpc.read_frame(reader(""), -1))));
print("header spaces: [" + rpc.header_value("CONTENT-LENGTH:   42", "content-length") + "]");
print("wrong header: [" + rpc.header_value("Content-Lengthy: 4", "content-length") + "]");

// Force several refills without creating a file in the checkout.
let fd = syscall(319, "lsp-framing", 1);
if (fd < 0) { eputs("memfd failed"); exit(1); };
let body = "x".repeat(150000);
fs.write_text(fd, "Content-Length: " + tostring(len(body)) + "\r\n\r\n" + body);
syscall(8, fd, 0, 0);
let stream = rpc.in_new();
print("large body exact: " + tostring(rpc.read_frame(stream, fd)! == body));
print("buffer bounded: " + tostring(len(stream.buf) <= 65536));
fs.close_file(fd);
