// Y Playground app — wires the WASM compiler to a CodeMirror editor + file tree.
"use strict";

let Module = null;
let editor = null;
const files = {};          // path -> source
let activePath = null;
const outputEl = document.getElementById("output");

const DEFAULT_FILES = {
  "main.y": `// Welcome to the Y Playground!
// This compiler runs entirely in your browser as WebAssembly.

def fib(n: long) -> long {
    if (n < 2) { n } else { self(n - 1) + self(n - 2) }
};

let i = 0;
while (i < 10) {
    print("fib(" + tostring(i) + ") = " + tostring(fib(i)));
    i = i + 1;
};
`,
  "math.y": `// A second file — click its ▶ button to run it.
def square(x: long) -> long { x * x };

let total = 0;
foreach (n in [1, 2, 3, 4, 5]) {
    total = total + square(n);
};
print("sum of squares = " + tostring(total));
`,
};

// ── output helpers ───────────────────────────────────────────────────────
function appendOutput(text, cls) {
  const span = document.createElement("span");
  if (cls) span.className = cls;
  span.textContent = text;
  outputEl.appendChild(span);
  outputEl.scrollTop = outputEl.scrollHeight;
}
function clearOutput() { outputEl.textContent = ""; }

// ── file tree ────────────────────────────────────────────────────────────
function renderTree() {
  const tree = document.getElementById("tree");
  tree.textContent = "";
  Object.keys(files).sort().forEach((path) => {
    const item = document.createElement("div");
    item.className = "tree-item" + (path === activePath ? " active" : "");

    const icon = document.createElement("span");
    icon.className = "icon";
    icon.textContent = "📄";

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = path;
    name.onclick = () => openFile(path);

    const run = document.createElement("button");
    run.className = "run-btn";
    run.textContent = "▶";
    run.title = "Run " + path;
    run.onclick = (e) => { e.stopPropagation(); openFile(path); runFile(path); };

    const del = document.createElement("button");
    del.className = "del-btn";
    del.textContent = "×";
    del.title = "Delete " + path;
    del.onclick = (e) => { e.stopPropagation(); deleteFile(path); };

    item.appendChild(icon);
    item.appendChild(name);
    item.appendChild(run);
    item.appendChild(del);
    item.ondblclick = () => openFile(path);
    tree.appendChild(item);
  });
}

function openFile(path) {
  if (activePath && editor) files[activePath] = editor.getValue();
  activePath = path;
  editor.setValue(files[path] || "");
  editor.focus();
  renderTree();
}

function newFile() {
  let n = 1, name = "untitled.y";
  while (files[name]) { name = "untitled" + n + ".y"; n++; }
  files[name] = "// " + name + "\nprint(\"hello from " + name + "\");\n";
  openFile(name);
}

function deleteFile(path) {
  if (!confirm("Delete " + path + "?")) return;
  delete files[path];
  if (activePath === path) {
    const rest = Object.keys(files);
    activePath = rest.length ? rest[0] : null;
    if (activePath) editor.setValue(files[activePath]);
    else editor.setValue("");
  }
  renderTree();
}

// ── run ──────────────────────────────────────────────────────────────────
function runActive() { if (activePath) runFile(activePath); }

function runFile(path) {
  if (!Module) { appendOutput("compiler not ready yet\n", "err"); return; }
  // save current editor content into the file model
  if (activePath && editor) files[activePath] = editor.getValue();

  clearOutput();
  appendOutput("── running " + path + " ──\n", "ok");

  // Write every file into MEMFS so imports resolve, under /src.
  try { Module.FS.mkdirTree("/src"); } catch (e) {}
  Object.keys(files).forEach((p) => {
    try { Module.FS.writeFile("/src/" + p, files[p]); } catch (e) {}
  });

  const t0 = performance.now();
  try {
    Module.callMain(["-q", "/src/" + path]);
    const ms = (performance.now() - t0).toFixed(1);
    appendOutput("── done in " + ms + "ms ──\n", "ok");
  } catch (e) {
    appendOutput(String(e) + "\n", "err");
  }
}

// ── resize handle ────────────────────────────────────────────────────────
(function () {
  const handle = document.getElementById("resize");
  const outWrap = document.getElementById("output-wrap");
  let dragging = false;
  handle.addEventListener("mousedown", () => { dragging = true; document.body.style.userSelect = "none"; });
  window.addEventListener("mouseup", () => { dragging = false; document.body.style.userSelect = ""; });
  window.addEventListener("mousemove", (e) => {
    if (!dragging) return;
    const center = document.getElementById("center").getBoundingClientRect();
    const h = center.bottom - e.clientY;
    outWrap.style.height = Math.max(60, Math.min(h, center.height - 100)) + "px";
    editor.refresh();
  });
})();

// ── export native wasm (lazy-loaded AssemblyScript) ──────────────────────
let emitModule = null;
let emitOutput = "";
let ascModule = null;

async function loadEmitModule() {
  if (emitModule) return emitModule;
  appendOutput("Loading Y→AS emitter…\n");
  emitModule = await createEmitAS({
    print: (t) => { emitOutput += t + "\n"; },
    printErr: (t) => appendOutput("[emit] " + t + "\n", "err"),
  });
  return emitModule;
}

async function loadAscModule() {
  if (ascModule) return ascModule;
  appendOutput("Loading AssemblyScript compiler (~2.9MB)…\n");
  // Set up importmap for AS CDN modules (lazy, only on first export)
  if (!document.querySelector('script[type="importmap"]')) {
    const im = document.createElement("script");
    im.type = "importmap";
    im.textContent = JSON.stringify({
      imports: {
        "assemblyscript": "https://cdn.jsdelivr.net/npm/assemblyscript@0.28.20/dist/assemblyscript.js",
        "assemblyscript/asc": "https://cdn.jsdelivr.net/npm/assemblyscript@0.28.20/dist/asc.js",
        "binaryen": "https://cdn.jsdelivr.net/npm/binaryen@131.0.0-nightly.20260721/index.js",
        "long": "https://cdn.jsdelivr.net/npm/long@5.3.2/index.js",
      }
    });
    document.head.appendChild(im);
    // es-module-shims for importmap support in older browsers
    const shims = document.createElement("script");
    shims.async = true;
    shims.src = "https://cdn.jsdelivr.net/npm/es-module-shims@1/dist/es-module-shims.wasm.min.js";
    document.head.appendChild(shims);
    await new Promise(r => setTimeout(r, 500)); // let shims load
  }
  const asc = await import("assemblyscript/asc");
  ascModule = asc.default || asc;
  appendOutput("AssemblyScript ready.\n", "ok");
  return ascModule;
}

function yToAssemblyScript(ySource) {
  emitOutput = "";
  emitModule.FS.writeFile("/input.y", ySource);
  emitModule.callMain(["/input.y"]);
  // The C runtime's print() prepends "[print] " to each line — strip it.
  return emitOutput.split("\n").map((l) =>
    l.startsWith("[print] ") ? l.slice(8) : l
  ).join("\n");
}

async function exportWasm() {
  if (!activePath) { appendOutput("No file selected.\n", "err"); return; }
  if (activePath && editor) files[activePath] = editor.getValue();
  const src = files[activePath];
  if (!src) { appendOutput("Empty file.\n", "err"); return; }

  clearOutput();
  appendOutput("── exporting " + activePath + " → native wasm ──\n", "ok");

  try {
    // Step 1: Y → AssemblyScript
    const em = await loadEmitModule();
    const asSource = yToAssemblyScript(src);
    appendOutput("Generated AssemblyScript (" + asSource.length + " chars)\n");

    // Step 2: AS → wasm (lazy-load compiler)
    const asc = await loadAscModule();
    const { binary, error, stderr } = await asc.compileString(asSource, { optimizeLevel: 3 });
    if (error) {
      appendOutput("AS compile error: " + error.message + "\n", "err");
      appendOutput(stderr.toString() + "\n", "err");
      return;
    }
    appendOutput("Compiled to " + binary.length + " bytes of wasm\n", "ok");

    // Step 3: download
    const blob = new Blob([binary], { type: "application/wasm" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = activePath.replace(/\.y$/, "") + ".wasm";
    a.click();
    URL.revokeObjectURL(url);
    appendOutput("Downloaded " + a.download + "\n", "ok");
  } catch (e) {
    appendOutput("Export failed: " + e + "\n", "err");
  }
}

// ── boot ─────────────────────────────────────────────────────────────────
editor = CodeMirror.fromTextArea(document.getElementById("editor"), {
  mode: "y",
  theme: "material-darker",
  lineNumbers: true,
  indentUnit: 4,
  tabSize: 4,
  indentWithTabs: false,
  matchBrackets: true,
});
editor.setOption("extraKeys", {
  "Ctrl-Enter": runActive,
  "Cmd-Enter": runActive,
});

Object.assign(files, DEFAULT_FILES);
activePath = "main.y";
editor.setValue(files[activePath]);
renderTree();

const statusEl = document.getElementById("status");
createYcc({
  print: (t) => appendOutput(t + "\n"),
  printErr: (t) => appendOutput(t + "\n", "err"),
}).then((m) => {
  Module = m;
  statusEl.textContent = "compiler ready";
  document.getElementById("run-btn").disabled = false;
  document.getElementById("export-btn").disabled = false;
}).catch((e) => {
  statusEl.textContent = "failed to load compiler";
  appendOutput("Failed to load compiler: " + e + "\n", "err");
});
