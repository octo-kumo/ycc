// Meta declarations and shared module context use the compiler's own passes.
import diag from "../diag.y";
import scan from "../scan.y";
import xref from "../xref.y";
import fmt from "../fmt.y";

let scratch = exec_capture("mktemp -d -t y-lsp-meta.XXXXXXXX").trim();
let meta_src = "#{\n    import schema from \"./schema.y\";\n    \"const ANSWER = \" + tostring(schema.VALUE) + \"; print(ANSWER);\"\n}#\n";
fs.write_file(scratch + "/schema.y", "const VALUE = 42;\nexport { VALUE };\n");
print("delimiters scan cleanly: " + tostring(len(scan.scan_full(meta_src).bad) == 0));
print("formatter preserves meta source: " + tostring(fmt.fmt(meta_src) == none));
print("stray hash remains invalid: " + tostring(len(scan.scan_full("let x = #;").bad) > 0));
print("meta import and declaration: " + tostring(len(diag.diagnose(meta_src, scratch, scratch + "/main.y", "", 0)) == 0));
let broken = diag.diagnose("#{\n\"const X = 1;\"", scratch, scratch + "/main.y", "", 0);
print("unfinished block: " + tostring(len(broken) == 1 && broken[0].msg.contains("unterminated #{ block") && broken[0].line == 1));
let failed = diag.diagnose("#{ no_such_generator() }#", scratch, scratch + "/main.y", "", 0);
print("generator failure is a finding: " + tostring(len(failed) == 1 && failed[0].msg.contains("undefined function 'no_such_generator'")));
print("next check survives: " + tostring(len(diag.diagnose("print(42);", scratch, scratch + "/main.y", "", 0)) == 0));

fs.make_dir(scratch + "/modules");
fs.write_file(scratch + "/.ycontext", "entry.y\n");
fs.write_file(scratch + "/entry.y", "type Ambient = { n: long };\nconst BASE = 41;\nimport part from \"./modules/part.y\";\nprint(part.value({n: 1}));\n");
let mod_path = scratch + "/modules/part.y";
let mod_src = "// A module header.\ndef value(x: Ambient) -> long {\n    x.n + BASE\n};\n";
fs.write_file(mod_path, mod_src);
print("shared declarations: " + tostring(len(diag.diagnose(mod_src, scratch + "/modules", mod_path, "", 0)) == 0));
let edited = mod_src.replace("x.n + BASE", "x.n + \"bad\"");
let findings = diag.diagnose(edited, scratch + "/modules", mod_path, "", 0);
let own_error = false;
foreach (finding in findings) {
    if (finding.file == mod_path && finding.line == 2 && finding.msg.contains("str")) { own_error = true; };
};
print("unsaved edit uses module coordinates: " + tostring(own_error));
print("disk source untouched: " + tostring(fs.read_file(mod_path)! == mod_src));
print("overlay cleared: " + tostring(len(diag.diagnose(mod_src, scratch + "/modules", mod_path, "", 0)) == 0));
let prepared = diag.xref_for(mod_src, scratch + "/modules", mod_path, "");
let mapped = false;
if (prepared != none) {
    let p = prepared!;
    let ln = xref.indexed_line(p.mine, 3);
    mapped = ln > 3 && expr_type(ln, 5).k != K.tunk;
};
print("module type index maps its own lines: " + tostring(mapped));
print("unrelated file checks independently: " + tostring(len(diag.diagnose("print(1);", scratch, scratch + "/orphan.y", "", 0)) == 0));
fs.remove_all(scratch);

foreach (compiler_file in ["src/y/asm.y", "src/y/array_lower.y"]) {
    let compiler_src = fs.read_file(compiler_file)!;
    print(compiler_file + " diagnostics: " + tostring(len(diag.diagnose(compiler_src, "src/y", compiler_file, "", 0))));
};
