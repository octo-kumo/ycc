// Test harness: run the Y compiler (wasm) on a .y source string, capture output.
// This mirrors exactly what the browser frontend will do.
const createYcc = require('./ycc.js');

async function runY(source, filename = '/prog.y') {
  let output = '';
  const Module = await createYcc({
    print: (t) => { output += t + '\n'; },
    printErr: (t) => { output += '[stderr] ' + t + '\n'; },
  });
  const FS = Module.FS;
  FS.writeFile(filename, source);
  try {
    Module.callMain([filename]);
  } catch (e) {
    output += '[exit] ' + e + '\n';
  }
  return output;
}

(async () => {
  console.log('=== TEST 1: pi.y ===');
  const pi = require('fs').readFileSync('../examples/pi.y', 'utf8');
  console.log(await runY(pi, '/pi.y'));

  console.log('=== TEST 2: hello world inline ===');
  console.log(await runY('print("hello from wasm");\nprint(1 + 2 * 3);\n'));

  console.log('=== TEST 3: multi-file import ===');
  const Module = await createYcc({ print: () => {}, printErr: () => {} });
  const FS = Module.FS;
  FS.mkdir('/proj');
  FS.writeFile('/proj/lib.y', 'def double(x: long) -> long { x * 2 };\nexport { double };\n');
  FS.writeFile('/proj/main.y', 'import lib from "./lib.y";\nprint(lib.double(21));\n');
  let out = '';
  // re-create with capture for the actual run
  const M2 = await createYcc({ print: (t) => out += t + '\n', printErr: (t) => out += '[err] ' + t + '\n' });
  M2.FS.mkdir('/proj');
  M2.FS.writeFile('/proj/lib.y', 'def double(x: long) -> long { x * 2 };\nexport { double };\n');
  M2.FS.writeFile('/proj/main.y', 'import lib from "./lib.y";\nprint(lib.double(21));\n');
  try { M2.callMain(['/proj/main.y']); } catch (e) { out += '[exit] ' + e + '\n'; }
  console.log(out);
})();
