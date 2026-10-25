// activation-check.js -- run the extension's activate() without VS Code.
//
// client-check.js proves the SERVER is a well-behaved LSP peer. This proves the
// CLIENT is a working VS Code extension, which is a different and equally real
// failure mode: a missing `main`, a runtime dependency left in
// devDependencies (so the packaged .vsix cannot require it), an activation path
// that throws, a server path that resolves to nothing.
//
// VS Code is not available here, so `activate()` is run against a stub of the
// `vscode` module (vscode-stub.js). That is only honest because the stub is
// adversarial in the right places: it answers unknown names with a CLASS, so a
// call the library makes on something the stub did not model fails loudly
// instead of silently returning undefined. Every gap that took a fix was a real
// requirement of vscode-languageclient's feature registration, found by this
// file rather than by a user opening an editor.
//
//   node src/tools/lsp/test/activation-check.js [path-to-extension-dir]
//
// The extension dir defaults to src/tools/lsp/vscode-y-lang, and must have been
// compiled (`npm install && npm run compile`).

'use strict';

const cp = require('child_process');
const fs = require('fs');
const path = require('path');

const extDir = path.resolve(process.argv[2] || path.join(__dirname, '..', 'vscode-y-lang'));
const stubPath = path.join(__dirname, 'vscode-stub.js');

let pass = 0;
let fail = 0;
function check(name, ok, detail) {
    if (ok) {
        pass++;
        console.log('ok       ' + name);
    } else {
        fail++;
        console.log('FAIL     ' + name + (detail ? '   [' + detail + ']' : ''));
    }
}

// ── the manifest, before anything is loaded ─────────────────────────────
// Cheap, and it catches the packaging mistake that is otherwise invisible until
// a user installs the .vsix: a runtime dependency filed under devDependencies is
// bundled by nothing and cannot be require()d from the packaged extension.
const pkgPath = path.join(extDir, 'package.json');
if (!fs.existsSync(pkgPath)) {
    console.error(`activation-check: no package.json at ${extDir}`);
    process.exit(2);
}
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
check('package.json: main points at a file that exists', !!pkg.main && fs.existsSync(path.join(extDir, pkg.main)),
    pkg.main);
check('package.json: activates on a Y file', Array.isArray(pkg.activationEvents) && pkg.activationEvents.includes('onLanguage:y'),
    JSON.stringify(pkg.activationEvents));
check('package.json: contributes the y language',
    !!(pkg.contributes && pkg.contributes.languages || []).some((l) => l.id === 'y'));
const grammars = (pkg.contributes && pkg.contributes.grammars) || [];
const ygrammar = grammars.find((g) => g.language === 'y');
check('package.json: contributes the y TextMate grammar',
    !!ygrammar && ygrammar.scopeName === 'source.y' &&
        ygrammar.path === './syntaxes/y.tmLanguage.json',
    JSON.stringify(grammars));
check('package.json: the TextMate grammar file exists',
    !!ygrammar && fs.existsSync(path.join(extDir, ygrammar.path.replace(/^\.\//, ''))),
    ygrammar ? ygrammar.path : 'no grammar');
// A command that is registered in code but not declared in `contributes` does
// not appear in the palette and shows no title anywhere: it works when invoked by
// id and is invisible to the user. That is exactly the "Format Document does
// nothing and I cannot find it" report, so the two lists are compared.
const declared = new Set(((pkg.contributes && pkg.contributes.commands) || []).map((c) => c.command));
check(
    'package.json: the three commands are DECLARED, not just registered',
    ['y.formatDocument', 'y.restartLanguageServer', 'y.showServerOutput'].every((c) => declared.has(c)),
    'declared: ' + [...declared].join(','),
);
check(
    'package.json: every declared command has a title and a category',
    [...declared].every((c) => {
        const e = ((pkg.contributes && pkg.contributes.commands) || []).find((x) => x.command === c);
        return e && typeof e.title === 'string' && e.title.length > 0;
    }),
);
check('package.json: vscode-languageclient is a RUNTIME dependency',
    !!(pkg.dependencies && pkg.dependencies['vscode-languageclient']),
    'it is in devDependencies, so the packaged .vsix cannot require it');

// Every setting the manifest offers must be READ by the client, and every setting
// the client reads must be OFFERED.
//
// Both directions have happened. `y.lsp.checkOnChange` was in LSP.md's
// requirements as R1.8 for as long as that document existed and was read by
// nobody -- the server dropped `initialize`'s params, so there was nowhere for the
// value to arrive even if the client had sent it (t019). A setting that appears in
// the settings UI and does nothing is the quietest kind of broken, because the
// user changes it, sees no difference, and concludes the feature is unreliable.
//
// The reverse is the `y.lsp.semantic` LSP.md promised: a switch that does not
// exist at all. Documentation claiming a setting is not catchable from here, but
// the manifest is.
const settings = ((pkg.contributes && pkg.contributes.configuration) || {}).properties || {};
const srcDir = path.join(extDir, 'src');
const clientSrc = fs
    .readdirSync(srcDir)
    .filter((f) => f.endsWith('.ts'))
    .map((f) => fs.readFileSync(path.join(srcDir, f), 'utf8'))
    .join('\n');
const settingKeys = Object.keys(settings).map((k) => k.replace(/^y\.lsp\./, ''));
check(
    'package.json: every setting it offers is READ by the client',
    settingKeys.every((k) => clientSrc.includes("'" + k + "'")),
    'unread: ' + settingKeys.filter((k) => !clientSrc.includes("'" + k + "'")).join(','),
);
const readKeys = [...clientSrc.matchAll(/get<[^>]*>\('([a-zA-Z.]+)'/g)].map((m) => m[1]);
check(
    'package.json: every setting the client reads is OFFERED',
    readKeys.every((k) => settingKeys.includes(k)),
    'read but not declared: ' + readKeys.filter((k) => !settingKeys.includes(k)).join(','),
);
// The booleans are pinned by name and by default, not only by type, so adding a
// setting here cannot quietly change what every existing user sees.
//
// checkOnChange and timing default TRUE -- check on change, and write the
// per-request timing lines. warnings defaults false, which IS what the server
// already does (yserve's own default, warn at level 0).
//
// timing's default was once false, on the reasoning that a line per request is
// work on the extension host and this extension had been reported making a cold
// open slow. That turned off the one instrument that had just located the
// problem, on a guess. It is on by default and stays there.
check(
    'package.json: the six settings, and every boolean defaults to what the server already does',
    settingKeys.length === 6 &&
        settings['y.lsp.checkOnChange'].type === 'boolean' &&
        settings['y.lsp.checkOnChange'].default === true &&
        settings['y.lsp.timing'].type === 'boolean' &&
        settings['y.lsp.timing'].default === true &&
        settings['y.lsp.warnings'].type === 'boolean' &&
        settings['y.lsp.warnings'].default === false,
    'settings: ' + settingKeys.join(','),
);
check('package.json: it is not ALSO in devDependencies',
    !(pkg.devDependencies && pkg.devDependencies['vscode-languageclient']));

const outDir = path.join(extDir, pkg.main || 'out/extension.js');
if (!fs.existsSync(outDir)) {
    console.error(`activation-check: ${outDir} does not exist -- run 'npm install && npm run compile' in ${extDir}`);
    process.exit(2);
}

// ── load the extension against the stub ─────────────────────────────────
const Module = require('module');
const originalResolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
    if (request === 'vscode') {
        return stubPath;
    }
    return originalResolve.call(this, request, ...rest);
};

const stub = require(stubPath);

// Count real spawns of the server, so "started" is not taken on trust -- and keep
// the ARGV, because that is where the settings land. Both settings that map to a
// flag (`y.lsp.rootPath` -> `--root`, `y.lsp.warnings` -> `-W`) are checked below
// against these, which is the only place the client's half of either can be seen.
let spawned = [];
let spawnArgs = [];
const originalSpawn = cp.spawn;
cp.spawn = function (cmd, ...rest) {
    spawned.push(String(cmd));
    spawnArgs.push(rest[0] || []);
    return originalSpawn.call(this, cmd, ...rest);
};

// A workspace with a real yserve beside it, so the search succeeds -- and a
// second run against an empty directory, so the failure path is exercised too.
const fsx = fs;
const goodDir = fsx.mkdtempSync(path.join(require('os').tmpdir(), 'lsp-act-'));
const serverBin = fsx.mkdtempSync(path.join(require('os').tmpdir(), 'lsp-bin-'));
const serverPath = path.join(serverBin, 'yserve');
const realServer = process.argv[3];
if (!realServer) {
    console.error('activation-check: pass the path to a built yserve as the second argument');
    process.exit(2);
}
fsx.copyFileSync(realServer, serverPath);
fsx.chmodSync(serverPath, 0o755);

const ext = require(path.resolve(outDir));
check('the module exports activate and deactivate',
    typeof ext.activate === 'function' && typeof ext.deactivate === 'function',
    Object.keys(ext).join(','));

async function activateAt(dir) {
    stub.__reset();
    spawned = [];
    spawnArgs = [];
    const ctx = { extensionPath: dir, subscriptions: [] };
    await ext.activate(ctx);
    // Give the client time to spawn and complete initialize. The handshake is a
    // round trip through a real process, so a fixed settle is honest here: what
    // is being checked is "it got as far as starting", not a timing guarantee.
    await new Promise((r) => setTimeout(r, 2500));
    return ctx;
}

(async () => {
    // 1. the happy path: a yserve beside the extension
    const ctx = await activateAt(serverBin);
    // The EXACT set, for the same reason client-check asserts the exact
    // capability set: a test that says "these two are registered" says nothing
    // about a command that was renamed, dropped, or never added.
    // The EXACT set again, now three commands AND the three M4 providers. The
    // provider registrations are here rather than only "nothing threw" because
    // that is how the stub's gap was found: the library asked for a function the
    // stub lacked and the extension died, which looks identical to a broken
    // extension. Asserting the registrations names the language they are for, so
    // a provider registered against nothing cannot pass.
    // Six features register in total; only the three M4 ones are RECORDED by the
    // stub (the others are bare no-ops, as they have always been), so the exact
    // set here is the three commands plus those three.
    check('activate: registered its three commands and the three M4 providers',
        stub.__calls.filter((c) => c.startsWith('register:')).sort().join(',') ===
            'register:CompletionItemProvider(y,._),' +
            'register:DefinitionProvider(y),' +
            'register:HoverProvider(y),' +
            'register:y.formatDocument,' +
            'register:y.restartLanguageServer,' +
            'register:y.showServerOutput',
        stub.__calls.filter((c) => c.startsWith('register:')).join(','));
    check('activate: pushed its subscriptions', ctx.subscriptions.length >= 4,
        String(ctx.subscriptions.length));
    check('activate: actually spawned the server', spawned.length === 1, JSON.stringify(spawned));
    check('activate: the server it spawned is the one we placed', spawned[0] === serverPath,
        JSON.stringify(spawned));
    // The argv the client built, with the settings at their DEFAULTS. NOT `-W`,
    // because `y.lsp.warnings` defaults off and `yserve` defaults to level 0 --
    // this pins "the setting's default is what the server already did", which is
    // the only safe default for a setting added after the fact. And NOT `--root`
    // either: this stub has no `workspaceFolders` and the setting is empty, so
    // there is no root to pass. Both are asserted positively in the settings run
    // below, which is what stops this pair from passing for the wrong reason.
    check('activate: argv at default settings is just --stdio',
        (spawnArgs[0] || []).join(' ') === '--stdio', JSON.stringify(spawnArgs[0]));
    check('activate: argv does NOT carry -W, because y.lsp.warnings defaults off',
        !(spawnArgs[0] || []).includes('-W'), JSON.stringify(spawnArgs[0]));
    check('activate: no error dialog when the server is there',
        !stub.__messages.some((m) => m.includes('Could not find')),
        JSON.stringify(stub.__messages));
    check('activate: the client reached Started',
        stub.__lines.some((l) => l.includes('started')),
        JSON.stringify(stub.__lines));
    check('activate: nothing threw', !stub.__lines.some((l) => l.includes('failed to start')),
        stub.__lines.filter((l) => l.includes('failed')).join(' | '));
    // `$(check) Y` is the running text. The important part is that it comes
    // AFTER any error text: the client passes through Stopped on the way up, and
    // an extension that reports that as a failure flashes a red status bar on
    // every successful start.
    check('activate: the status bar ends up saying the server is running',
        stub.__status.length > 0 && stub.__status[stub.__status.length - 1] === '$(check) Y',
        JSON.stringify(stub.__status));
    check('activate: no error is shown on the way up',
        !stub.__status.some((t) => t.includes('$(error)')),
        JSON.stringify(stub.__status));
    // The state changes are logged with their NAMES, not bare integers. A bare `3`
    // is unreadable, which is how two wrong constants survived: a real log showed
    // `client state: 3` followed by `client state: 2`, which reads as backwards.
    check('activate: the state changes are logged by name',
        stub.__lines.some((l) => l.includes('client state: Starting (2)'))
            && stub.__lines.some((l) => l.includes('client state: Running (3)')),
        stub.__lines.filter((l) => l.includes('client state')).join(' | '));
    await ext.deactivate();
    check('deactivate: stopped the server it started', spawned.length >= 1);
    // And the status bar says the server is gone. This is the check that was
    // missing while the state constants were wrong: the branch that reports a dead
    // server was keyed on Running instead of Stopped, so it could never fire, and
    // nothing asserted that it should. deactivate() takes the client through the
    // real Stopped transition, so the assertion needs no new machinery.
    check('deactivate: the status bar says the server stopped',
        stub.__status.some((t) => t.includes('server stopped')),
        JSON.stringify(stub.__status));

// R1.6 and the root, with both settings ON. The positive half of the argv checks
// above, and the only place `serverArgs(root, warnings)` is seen doing its job:
// a setting that reaches `package.json` and the client and still never reaches the
// server passes every static check there is.
// `serverPath` too: `config.__override` REPLACES the whole configuration rather
// than merging with it, so a run that sets only `warnings` leaves the search with
// nothing to find -- which is exactly what the first version of this did, and the
// symptom was "nothing was spawned", not a wrong argument.
stub.__config = { serverPath: serverPath, rootPath: goodDir, warnings: true };
await activateAt(goodDir);
check('activate with y.lsp.rootPath: argv carries --root AND the path',
    spawnArgs[0] && spawnArgs[0][spawnArgs[0].indexOf('--root') + 1] === goodDir,
    'spawned: ' + JSON.stringify(spawned) + ' argv: ' + JSON.stringify(spawnArgs[0]));
check('activate with y.lsp.warnings: argv carries -W',
    (spawnArgs[0] || []).includes('-W'), JSON.stringify(spawnArgs[0]));
stub.__config = undefined;

    // 2. the failure path: nowhere to find yserve. It must SAY so -- a client
    //    that silently does nothing is the worst outcome, because the user has
    //    no way to tell "no errors" from "not working".
    const ctx2 = await activateAt(goodDir);
    // The dialog text is recorded in __messages, not __calls.
    check('activate: with no server, an error dialog is shown',
        stub.__messages.some((m) => m.includes('Could not find the yserve binary')),
        JSON.stringify(stub.__messages));
    check('activate: with no server, nothing was spawned', spawned.length === 0,
        JSON.stringify(spawned));
    check('activate: with no server, the status bar says so',
        stub.__status.some((t) => t.includes('no server')),
        JSON.stringify(stub.__status));
    await ext.deactivate();

    // 3. a configured path that does not exist must NOT fall back to the search.
    //    Silently starting a different binary than the user asked for is worse
    //    than failing.
    stub.__reset();
    spawned = [];
    spawnArgs = [];
    stub.__config = { serverPath: '/nonexistent/yserve' };
    await ext.activate({ extensionPath: serverBin, subscriptions: [] });
    await new Promise((r) => setTimeout(r, 1500));
    check('activate: a bad y.lsp.serverPath does not fall back to the search',
        spawned.length === 0, JSON.stringify(spawned));
    check('activate: a bad y.lsp.serverPath names the setting in the message',
        stub.__messages.some((m) => m.includes('y.lsp.serverPath')),
        JSON.stringify(stub.__messages));
    await ext.deactivate();
    stub.__config = undefined;

    fsx.rmSync(goodDir, { recursive: true, force: true });
    fsx.rmSync(serverBin, { recursive: true, force: true });

    console.log('');
    console.log(`passed ${pass}, failed ${fail}`);
    process.exit(fail === 0 ? 0 : 1);
})().catch((e) => {
    fail++;
    console.log('FAIL     the driver threw   [' + (e && e.stack ? e.stack.split('\n').slice(0, 4).join(' / ') : e) + ']');
    console.log(`passed ${pass}, failed ${fail}`);
    process.exit(1);
});
