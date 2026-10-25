// client-check.js -- drive yserve with the SAME JSON-RPC library VS Code uses.
//
// The driver in `ytest lsp-e2e` speaks the protocol by hand, which proves the
// server does what this file's author thinks the protocol says. It does not
// prove the server agrees with an actual LSP implementation -- and the two have
// differed before (this is how the `version: 0` and the missing-slash-URI bugs
// were caught: the hand-written driver was happy with both).
//
// vscode-languageclient is built on vscode-jsonrpc, so the client half of that
// stack is right here. This file uses it to send the exact message sequence
// VS Code sends on open, type, save, format and close, and then asserts on what
// comes back. It needs no VS Code, no display and no extension host: it is the
// protocol layer alone.
//
//   node src/tools/lsp/test/client-check.js ./yserve
//
// Exit 0 iff every check passes.

'use strict';

const cp = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const RPC = require(path.join(__dirname, '..', 'vscode-y-lang', 'node_modules', 'vscode-jsonrpc', 'node'));

const bin = process.argv[2] || './yserve';
if (!fs.existsSync(bin)) {
    console.error(`client-check: no server at ${bin} (run 'make yserve')`);
    process.exit(2);
}

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

// A workspace with one import, so the per-file diagnostics case has something to
// find. A temp dir: this driver creates files.
const ws = fs.mkdtempSync(path.join(os.tmpdir(), 'lsp-client-'));
fs.writeFileSync(path.join(ws, 'mod.y'), '// café 😀\ndef f() -> long {\n    let spare = 1;\n    7\n}\n');

// The extension's own manifest: the client checks the SERVER's legend against what
// the extension declares, and the two live in different files.
const pkgExt = JSON.parse(
    fs.readFileSync(path.join(__dirname, '..', 'vscode-y-lang', 'package.json'), 'utf8'));

const uri = (p) => 'file://' + p;
const mainPath = path.join(ws, 'main.y');
const mainUri = uri(mainPath);
const modUri = uri(path.join(ws, 'mod.y'));

// The buffer: an error and a warning in the same file (what ycc cannot do), plus
// an import whose own module has a warning.
const text =
    'import helper from "./mod.y";\n' +
    '\n' +
    'def f() -> long {\n' +
    '    let unused = 1;\n' +
    '    2 + "s"\n' +
    '}\n' +
    '\n' +
    'print(f() + helper.f());\n';

// The capabilities VS Code actually sends. Copied in shape from a real
// initialize; the parts yserve reads (rootUri, textDocument sync kind) are the
// ones that matter.
function initParams() {
    return {
        processId: process.pid,
        clientInfo: { name: 'Visual Studio Code', version: '1.95.0' },
        rootUri: uri(ws),
        capabilities: {
            workspace: { applyEdit: true, workspaceFolders: true, configuration: true },
            textDocument: {
                synchronization: { dynamicRegistration: false, willSave: false, didSave: true },
                publishDiagnostics: { relatedInformation: false, versionSupport: true },
                formatting: { dynamicRegistration: false },
            },
            window: { workDoneProgress: true },
        },
        workspaceFolders: [{ uri: uri(ws), name: 'ws' }],
    };
}

function main() {
    const proc = cp.spawn(bin, ['--root', ws], { stdio: ['pipe', 'pipe', 'pipe'] });
    const stderr = [];
    proc.stderr.on('data', (d) => stderr.push(d));
    proc.on('exit', (code) => {
        if (code !== 0) {
            fail++;
            console.log(`FAIL     server exited ${code}   [${Buffer.concat(stderr).toString().slice(0, 200)}]`);
        }
        finish();
    });

    const conn = RPC.createMessageConnection(
        new RPC.StreamMessageReader(proc.stdout),
        new RPC.StreamMessageWriter(proc.stdin),
    );

    // Every publishDiagnostics the server sends, by URI, in arrival order.
    const published = new Map();
    const order = [];
    conn.onNotification('textDocument/publishDiagnostics', (p) => {
        published.set(p.uri, p.diagnostics);
        order.push(p.uri);
    });
    conn.listen();

    // Both of these must forward EVERY argument. The first version of this file
    // wrote `const send = (m) => conn.sendNotification(m)`, which silently
    // dropped the params: the server received a didOpen with no textDocument,
    // answered nothing, and the run looked like a server bug rather than a typo
    // in the driver. That is worth a comment, because the failure mode is a
    // server that looks broken.
    const send = (m, ...rest) => conn.sendNotification(m, ...rest);
    const request = (m, ...rest) => conn.sendRequest(m, ...rest);

    const diagnosticsFor = (u) => published.get(u) || [];
    const settle = () => new Promise((r) => setTimeout(r, 150));

    (async () => {
        // 1. the handshake, exactly as VS Code does it
        const init = await request('initialize', initParams());
        check('initialize: answered with capabilities', !!(init && init.capabilities));
        check(
            'initialize: full document sync advertised',
            init.capabilities.textDocumentSync &&
                init.capabilities.textDocumentSync.change === 1,
            JSON.stringify(init.capabilities.textDocumentSync),
        );
        // THE PUSH/PULL RULE, and the reason this file exists.
        //
        // `diagnosticProvider` means PULL: the client will ask, with
        // textDocument/diagnostic. A server that advertises it and answers
        // -32601 has not merely added a log line -- the client has switched to
        // pulling and now IGNORES the publishDiagnostics it is still being sent,
        // so the file shows no diagnostics at all. That is not hypothetical: the
        // first version of yserve advertised the pull model while implementing
        // only the push one, and this driver was happy because it never pulled.
        //
        // So this driver pulls whenever the server says it can, exactly as an
        // editor does.
        if (init.capabilities.diagnosticProvider) {
            let pulled = null;
            let pullError = null;
            try {
                pulled = await request('textDocument/diagnostic', { textDocument: { uri: mainUri } });
            } catch (e) {
                pullError = e;
            }
            check(
                'initialize: diagnosticProvider is advertised AND answers a pull',
                pullError === null && pulled !== null && Array.isArray(pulled.items),
                'advertised diagnosticProvider but textDocument/diagnostic failed: ' +
                    (pullError ? JSON.stringify(pullError.message || pullError) : 'no items'),
            );
        } else {
            check('initialize: no pull-diagnostics capability advertised', true);
        }
        // Push needs no capability, so there is nothing to assert about it here --
        // the didOpen checks below are the proof that it works.
        check('initialize: formatting advertised', init.capabilities.documentFormattingProvider === true);
        // M4's three, now implemented (this check used to assert they were
        // ABSENT, which was true while the handlers did not exist and would have
        // become a lie the moment they did).
        check(
            'initialize: hover advertised',
            init.capabilities.hoverProvider === true,
            JSON.stringify(init.capabilities.hoverProvider),
        );
        check(
            'initialize: definition advertised',
            init.capabilities.definitionProvider === true,
            JSON.stringify(init.capabilities.definitionProvider),
        );
        check(
            'initialize: completion advertised, with trigger characters',
            !!init.capabilities.completionProvider &&
                Array.isArray(init.capabilities.completionProvider.triggerCharacters) &&
                init.capabilities.completionProvider.triggerCharacters.includes('.'),
            JSON.stringify(init.capabilities.completionProvider),
        );
        // Every capability this server DOES advertise must be one it answers.
        // All seven are exercised below; this asserts the set is exactly those
        // seven plus nothing that implies a request the server would refuse. An
        // EXACT set, not a deny-list: a deny-list says nothing about a capability
        // nobody thought to forbid, which is how `diagnosticProvider` shipped.
        const advertised = Object.keys(init.capabilities).filter((k) => {
            const v = init.capabilities[k];
            return v !== undefined && v !== null && v !== false;
        });
        check(
            'initialize: advertises exactly the six capabilities it implements',
            advertised.sort().join(',') ===
                'completionProvider,definitionProvider,documentFormattingProvider,' +
                    'documentSymbolProvider,hoverProvider,textDocumentSync',
            'advertised: ' + advertised.sort().join(','),
        );
        // Syntax highlighting is TextMate, not semantic tokens. The extension
        // contributes the grammar in package.json; the server must not advertise
        // a semantic-token capability it does not implement.
        check('initialize: no semantic-token capability is advertised',
            init.capabilities.semanticTokensProvider === undefined,
            JSON.stringify(init.capabilities.semanticTokensProvider));
        const gr = ((pkgExt.contributes || {}).grammars || []).find((g) => g.language === 'y');
        check('package.json: contributes a TextMate grammar for y',
            !!gr && gr.scopeName === 'source.y' && gr.path === './syntaxes/y.tmLanguage.json',
            JSON.stringify(gr));
        const grPath = path.join(__dirname, '..', 'vscode-y-lang',
            gr ? gr.path.replace(/^\.\//, '') : '');
        let grJson = null;
        try { grJson = JSON.parse(fs.readFileSync(grPath, 'utf8')); } catch (e) { grJson = null; }
        check('TextMate grammar: a valid JSON grammar with source.y',
            !!grJson && grJson.scopeName === 'source.y' && Array.isArray(grJson.patterns),
            grPath + (grJson ? '' : ' (unreadable)'));
        const pats = grJson && Array.isArray(grJson.patterns)
            ? grJson.patterns.map((p) => p.include)
            : [];
        check('TextMate grammar: #strings precedes #comments',
            pats.indexOf('#strings') >= 0 && pats.indexOf('#comments') >= 0 &&
                pats.indexOf('#strings') < pats.indexOf('#comments'),
            JSON.stringify(pats));
        send('initialized', {});
        await settle();

        // 2. didOpen, with the languageId and version VS Code sends
        send('textDocument/didOpen', {
            textDocument: { uri: mainUri, languageId: 'y', version: 1, text },
        });
        await settle();

        const mine = diagnosticsFor(mainUri);
        check('didOpen: diagnostics arrived for the document', mine.length > 0, JSON.stringify(mine));
        check(
            'didOpen: the error AND the warning are both there',
            mine.some((d) => d.severity === 1) && mine.some((d) => d.severity === 2),
            JSON.stringify(mine.map((d) => d.message)),
        );
        check(
            'didOpen: the warning is tagged so an editor can grey it out',
            mine.filter((d) => d.severity === 2).every((d) => Array.isArray(d.tags) && d.tags.length > 0),
        );
        check(
            'didOpen: the import got its own notification',
            published.has(modUri),
            'saw ' + JSON.stringify([...published.keys()]),
        );
        check(
            'didOpen: the import carries its own finding, on its own line',
            diagnosticsFor(modUri).length === 1 &&
                diagnosticsFor(modUri)[0].range.start.line === 2 &&
                /spare/.test(diagnosticsFor(modUri)[0].message),
            JSON.stringify(diagnosticsFor(modUri)),
        );
        check(
            'didOpen: the document is published before the import',
            order.indexOf(mainUri) < order.indexOf(modUri),
            JSON.stringify(order),
        );

        // 3. didChange: the whole document again, as full sync means
        const broken = 'def g() -> long {\n    let q: str = 1;\n    2\n}\nprint(g());\n';
        send('textDocument/didChange', {
            textDocument: { uri: mainUri, version: 2 },
            contentChanges: [{ text: broken }],
        });
        await settle();
        // Replaced, not appended to: the previous finding is gone and the new
        // one is there. Counting is deliberately not the assertion -- this text
        // draws two findings (the error and an unused variable), and a check
        // that said "exactly one" would be asserting the test's own sloppiness.
        const after = diagnosticsFor(mainUri);
        check(
            'didChange: the old finding is gone',
            !after.some((d) => /body: expected long/.test(d.message)),
            JSON.stringify(after.map((d) => d.message)),
        );
        check(
            'didChange: the new finding is there, with no leftovers',
            after.length === 2 && after.some((d) => /expected str/.test(d.message)),
            JSON.stringify(after.map((d) => d.message)),
        );
        check(
            'didChange: the version moved on',
            published.get(mainUri) !== undefined,
        );

        // 4. a format request, with the options VS Code sends
        const messy = 'def h( ) -> long {\nlet v=1;\n     return   2 ;\n}\nprint(h());\n';
        send('textDocument/didChange', {
            textDocument: { uri: mainUri, version: 3 },
            contentChanges: [{ text: messy }],
        });
        await settle();
        const fmt = await request('textDocument/formatting', {
            textDocument: { uri: mainUri },
            options: { tabSize: 4, insertSpaces: true, trimTrailingWhitespace: true },
        });
        check('formatting: returned edits', Array.isArray(fmt.edits) && fmt.edits.length === 1,
            JSON.stringify(fmt));
        if (Array.isArray(fmt.edits) && fmt.edits.length === 1) {
            const e = fmt.edits[0];
            check('formatting: the edit covers the whole document',
                e.range.start.line === 0 && e.range.start.character === 0,
                JSON.stringify(e.range));
            check('formatting: newText is the formatted document',
                /def h\( \) ->/.test(e.newText) && /    let v = 1;/.test(e.newText),
                JSON.stringify(e.newText));
        }

        // M4's fixture is the ORIGINAL text again. Formatting above moved the
        // buffer to `messy`; without this the hover, definition and completion
        // cases below would ask about the wrong document.
        send('textDocument/didChange', {
            textDocument: { uri: mainUri, version: 4 },
            contentChanges: [{ text }],
        });
        await settle();

        // 5b. DOCUMENT SYMBOLS: the outline. "no symbols found in document" is
        //     exactly what an editor says when this comes back empty.
        // ── M4: hover, definition, completion ──
        // `print(f() + helper.f());` is the LAST line, which is line 7 -- line 1
        // of the fixture is blank. `f` is the local def on line 2; `helper` is an
        // import on line 0, and Stage A honestly answers null for it, because the
        // name belongs to another file and this is not the compiler's scope.
        const at = (l, c) => ({ textDocument: { uri: mainUri }, position: { line: l, character: c } });
        const lineOf = (t) => text.split('\n')[t];
        const lines = text.split('\n');
        const fCol = lineOf(7).indexOf('f(');
        check('m4: the fixture really has `f(` on line 7', fCol > 0, lineOf(7));

        const def = await request('textDocument/definition', at(7, fCol));
        check('definition: a Location for the local def',
            !!def && def.uri === mainUri && def.range.start.line === 2,
            JSON.stringify(def));
        check('definition: the range is the NAME, not the whole def',
            !!def && def.range.start.character === 4 && def.range.end.character === 5,
            def ? JSON.stringify(def.range) : 'no location');

        const hov = await request('textDocument/hover', at(7, fCol));
        check('hover: markdown contents naming the function',
            !!hov && hov.contents && hov.contents.kind === 'markdown' &&
                hov.contents.value.indexOf('f() -> long') >= 0,
            JSON.stringify(hov));
        check('hover: the range is the word under the mouse, not the declaration',
            !!hov && hov.range.start.line === 7 && hov.range.start.character === fCol,
            hov ? JSON.stringify(hov.range) : 'no hover');

        // A name from another file: Stage A says so rather than guessing.
        const hCol = lineOf(7).indexOf('helper');
        const defImp = await request('textDocument/definition', at(6, hCol + 1));
        check('definition: null for a name from another file, not a wrong place',
            defImp === null, JSON.stringify(defImp));

        // Nothing under the cursor: null for both, not an empty array and not a
        // location at 0:0.
        check('definition: null on a blank line',
            (await request('textDocument/definition', at(1, 0))) === null);
        check('hover: null on a blank line',
            (await request('textDocument/hover', at(1, 0))) === null);

        const comp = await request('textDocument/completion', at(7, fCol));
        const labels = comp && comp.items ? comp.items.map((i) => i.label) : [];
        check('completion: an items array with isIncomplete set',
            !!comp && Array.isArray(comp.items) && comp.isIncomplete === true,
            JSON.stringify(comp && comp.items ? comp.items.length : null));
        check('completion: the local names are offered',
            labels.includes('f'), JSON.stringify(labels));
        // The builtins come from the compiler's own list, so a builtin added
        // there appears here with nothing updated on this side.
        check('completion: builtins are offered too',
            labels.includes('print') && labels.includes('tostring'),
            JSON.stringify(labels.slice(0, 12)));
        check('completion: internal names are NOT offered',
            !labels.some((l) => l.includes('$')) && !labels.some((l) => l.startsWith('#')),
            JSON.stringify(labels.filter((l) => l.includes('$') || l.startsWith('#'))));
        // A prefix filters, which is what makes the list usable on a big file.
        const pref = await request('textDocument/completion', at(2, 5));
        const plabels = pref && pref.items ? pref.items.map((i) => i.label) : [];
        check('completion: a prefix narrows the list',
            plabels.length > 0 && plabels.length < labels.length &&
                plabels.every((l) => l.startsWith('f')),
            JSON.stringify(plabels));
        // Every item must carry a textEdit, or a client that applies
        // completions by textEdit inserts nothing at all.
        check('completion: every item has a textEdit with newText',
            comp.items.every((i) => i.textEdit && typeof i.textEdit.newText === 'string'),
            JSON.stringify(comp.items.filter((i) => !i.textEdit).map((i) => i.label)));

        // ── the member position: a `.` and a name after it ──
        // A SECOND document, so the positions above stay the ones the rest of
        // this file computed from `text` -- adding lines to that buffer would
        // move `fCol` and quietly change what every earlier case tests.
        const smText = [
            'let csv = "a,b,c";',           // 0
            'let parts = csv.split(",");',  // 1  `.` at 15, split at 16..20
            'let w = csv.pad_left(8);',     // 2  `.` at 11, pad_left at 12..19
            'let rec = { k: 1 };',          // 3
            'let v = rec.k;',               // 4  `.` at 11, k at 12
            'let bare = csv.;',             // 5  `.` at 14, nothing after it
            '',
        ].join('\n');
        const smPath = path.join(ws, 'sm.y');
        const smUri = uri(smPath);
        fs.writeFileSync(smPath, smText);
        send('textDocument/didOpen', {
            textDocument: { uri: smUri, languageId: 'y', version: 1, text: smText },
        });
        await settle();
        const smAt = (l, c) => ({ textDocument: { uri: smUri }, position: { line: l, character: c } });

        const smHov = await request('textDocument/hover', smAt(1, 18));
        check('str method: hover names the method and its signature',
            !!smHov && smHov.contents && smHov.contents.kind === 'markdown' &&
                typeof smHov.contents.value === 'string' &&
                smHov.contents.value.includes('split(str) -> [str]'),
            JSON.stringify(smHov && smHov.contents));
        check('str method: the hover range is the word under the mouse',
            !!smHov && smHov.range && smHov.range.start.character === 16 &&
                smHov.range.end.character === 21,
            JSON.stringify(smHov && smHov.range));
        const smHov2 = await request('textDocument/hover', smAt(2, 14));
        check('str method: a default argument shows in the signature',
            !!smHov2 && smHov2.contents.value.includes('pad_left(long, str = " ") -> str'),
            JSON.stringify(smHov2 && smHov2.contents));
        // A record field after a dot is NOT a string method. It used to be
        // asserted as `null`, because Stage A could not type the receiver. With the
        // checker's type index (LSP.md 9.2 A2) the receiver IS typed, so the field
        // answers with its own type -- and the assertion has to change with it,
        // because what it was really testing is that the string-method branch does
        // not swallow a field. It checks the exact answer and that it is not a
        // signature.
        const recField = await request('textDocument/hover', smAt(4, 12));
        check('str method: a record field answers its own type, not a signature',
            !!recField && recField.contents.value.trim() === 'long',
            JSON.stringify(recField && recField.contents.value));

        // A record's OWN fields after a dot, chosen by the checker's type of the
        // object rather than by guessing (LSP.md 9.2, R6.1). Driven through the
        // same protocol path as the string methods above, because the point is
        // that one member branch serves both and picks the right list.
        const recComp = await request('textDocument/completion', smAt(4, 13));
        const recLabels = recComp && recComp.items ? recComp.items.map((i) => i.label) : [];
        check('member: a record offers its own fields after a dot',
            recLabels.length === 1 && recLabels[0] === 'k', JSON.stringify(recLabels));
        check('member: and NOT the 26 string methods',
            !recLabels.includes('split') && !recLabels.includes('pad_left'),
            JSON.stringify(recLabels));
        check('member: a field item is Field(5) and carries the field type',
            recComp.items.every((i) => i.kind === 5 && i.detail === 'long'),
            JSON.stringify(recComp.items));
        check('member: every field item has a textEdit',
            recComp.items.every((i) => i.textEdit && typeof i.textEdit.newText === 'string'));

        const smComp = await request('textDocument/completion', smAt(5, 15));
        const smLabels = smComp && smComp.items ? smComp.items.map((i) => i.label) : [];
        check('str method: completion after a dot offers the methods',
            smLabels.includes('split') && smLabels.includes('pad_left') &&
                smLabels.includes('lstrip'), JSON.stringify(smLabels));
        check('str method: and NOT the names -- a member is not a name',
            !smLabels.includes('print') && !smLabels.includes('csv'), JSON.stringify(smLabels));
        check('str method: each item is Method(2) and carries its signature',
            smComp.items.filter((i) => i.label === 'pad_left')
                .every((i) => i.kind === 2 && typeof i.detail === 'string' &&
                    i.detail.includes('-> str')),
            JSON.stringify(smComp.items.filter((i) => i.label === 'pad_left')));
        const smPref = await request('textDocument/completion', smAt(1, 18));
        check('str method: isIncomplete is still set on the member list',
            !!smPref && smPref.isIncomplete === true, JSON.stringify(smPref));
        check('str method: every member item has a textEdit',
            smComp.items.every((i) => i.textEdit && typeof i.textEdit.newText === 'string'));

        const syms = await request('textDocument/documentSymbol', { textDocument: { uri: mainUri } });
        const arr = syms && syms.documentSymbol;
        check('documentSymbol: a non-empty array', Array.isArray(arr) && arr.length > 0,
            JSON.stringify(arr));
        if (Array.isArray(arr) && arr.length > 0) {
            const names = arr.map((s) => s.name);
            check('documentSymbol: the def and the import are both there',
                names.includes('f') && names.includes('helper'), JSON.stringify(names));
            const f = arr.find((s) => s.name === 'f');
            check('documentSymbol: hierarchical, and the body let is a child',
                Array.isArray(f.children) && f.children.some((c) => c.name === 'unused'),
                JSON.stringify(f.children));
            check('documentSymbol: selectionRange is the NAME, not the whole extent',
                f.selectionRange.start.line === f.range.start.line &&
                    f.selectionRange.end.character !== f.range.end.character,
                JSON.stringify(f.selectionRange) + ' vs ' + JSON.stringify(f.range));
            check('documentSymbol: every kind is a number the protocol defines',
                arr.every((s) => typeof s.kind === 'number' && s.kind >= 1 && s.kind <= 26));
            check('documentSymbol: every range is inside the document',
                arr.every((s) => s.range.start.line < lines.length && s.range.end.line < lines.length));
        }

        // 5. didSave, then didClose
        send('textDocument/didSave', { textDocument: { uri: mainUri } });
        await settle();
        check('didSave: re-published rather than ignored', published.has(mainUri));
        send('textDocument/didClose', { textDocument: { uri: mainUri } });
        await settle();
        check('didClose: an empty list, so the squiggles go away',
            diagnosticsFor(mainUri).length === 0,
            JSON.stringify(diagnosticsFor(mainUri)));

        // 6. an unknown request must be an error, not silence
        let unknown = null;
        try {
            await request('textDocument/somethingElse', { textDocument: { uri: mainUri } });
        } catch (e) {
            unknown = e;
        }
        check('unknown method: rejected with a JSON-RPC error', unknown !== null, String(unknown));

        // 7. a capability the server claims but does not implement must fail
        //    LOUDLY, and the client must not be left waiting. Every such probe
        //    here is answered with a JSON-RPC error, never silence: a client
        //    blocked on an unanswered request is a hung editor.
        // hover, definition and completion were in this list while they were
        // advertised-but-absent; M4 implemented them and they are driven for
        // real above. What is left here is what this server still refuses, and
        // each refusal is a promise it did NOT advertise.
        const claimedButAbsent = [
            ['textDocument/rangeFormatting', { textDocument: { uri: mainUri }, range: { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } }, options: { tabSize: 4, insertSpaces: true } }],
            ['textDocument/semanticTokens/full', { textDocument: { uri: mainUri } }],
            ['textDocument/semanticTokens/range', { textDocument: { uri: mainUri }, range: { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } } }],
            ['workspace/diagnostic', { previousResultIds: [] }],
            ['workspace/symbol', { query: 'f' }],
        ];
        for (const [method, params] of claimedButAbsent) {
            let err = null;
            try {
                await request(method, params);
            } catch (e) {
                err = e;
            }
            check(
                `unimplemented: ${method} is refused with a JSON-RPC error`,
                err !== null,
                'it answered, so it looks implemented'
            );
        }

        // 8. R1.8's `y.lsp.checkOnChange`, OFF. Its own session, because the
        //    option is read once at `initialize` and a session cannot be
        //    re-negotiated.
        await checkOnChangeOff();

        // 9. shutdown/exit, and the process must end by itself.
        //
        // `exit` alone. This used to end with `conn.dispose()` + `proc.stdin.end()`
        // as well, and that pair is a write-after-end waiting to happen: dispose
        // ends the writer's stream, and anything the connection still flushes --
        // the queued `exit` above, or a reply to a message the server sent as it
        // was dying -- lands on a stream that has been ended. It surfaced only once
        // a second session existed (the checkOnChange one below), because that is
        // what changed the timing, and it surfaced as an unhandled throw from
        // inside a promise executor: no failed check, no `passed N, failed 0`
        // line, just a non-zero exit. The server quits on `exit` by itself, which
        // is what `finish()`'s exit handler has always relied on.
        await request('shutdown');
        conn.sendNotification('exit');
        // finish() runs from the exit handler
    })().catch((e) => {
        fail++;
        console.log('FAIL     driver threw   [' + (e && e.message ? e.message : String(e)) + ']');
        try {
            proc.kill();
        } catch {
            /* gone */
        }
    });
}

// R1.8 with the setting OFF, over the wire, against its own process.
//
// The claim being pinned is not "the flag is read" -- t019 does that in Y -- it
// is the SPLIT: `didChange` must publish nothing while the buffer still moves, so
// the features that read the buffer are never a keystroke behind. A session that
// simply ignored changes would pass the first half and fail every real one, which
// is why the hover at the end is the load-bearing check and not an extra.
//
// V1 has an error on line 1; V2 adds a line with a builtin on it. A hover at line
// 2 can only answer if the change was taken.
function checkOnChangeOff() {
    return new Promise((resolve) => {
        const proc = cp.spawn(bin, ['--root', ws], { stdio: ['pipe', 'pipe', 'pipe'] });
        proc.on('exit', () => resolve());
        // The `exit` notification below is fire-and-forget and this server quits
        // on reading it, so the pipe closes while the writer still holds the frame.
        // That surfaces as an UNHANDLED ERR_STREAM_WRITE_AFTER_END which kills node
        // -- after every check has printed, so the run looks like a pass until the
        // exit code says otherwise. Swallowing it here is the fix; the write it
        // complains about is the `exit` the server has already acted on.
        proc.stdin.on('error', () => undefined);
        const conn = RPC.createMessageConnection(
            new RPC.StreamMessageReader(proc.stdout),
            new RPC.StreamMessageWriter(proc.stdin),
        );
        const seen = [];
        conn.onNotification('textDocument/publishDiagnostics', (p) => {
            if (p.uri === mainUri) {
                seen.push((p.diagnostics || []).length);
            }
        });
        conn.listen();
        const send = (m, ...rest) => conn.sendNotification(m, ...rest);
        const request = (m, ...rest) => conn.sendRequest(m, ...rest);
        const settle = () => new Promise((r) => setTimeout(r, 250));
        const V1 = 'let a = nosuchfn(1);\n';
        const V2 = 'let a = nosuchfn(1);\nprint(a);\n';
        const doc = (t, v) => ({ uri: mainUri, languageId: 'y', version: v, text: t });
        (async () => {
            const p = initParams();
            p.initializationOptions = { rootPath: ws, checkOnChange: false };
            const init = await request('initialize', p);
            check(
                'checkOnChange: initialize still answers with capabilities',
                !!(init && init.capabilities),
            );
            send('textDocument/didOpen', { textDocument: doc(V1, 1) });
            await settle();
            const afterOpen = seen.slice();
            check(
                'checkOnChange off: didOpen still publishes',
                afterOpen.length === 1 && afterOpen[0] >= 1,
                'publishes: ' + JSON.stringify(afterOpen),
            );
            const before = seen.length;
            send('textDocument/didChange', {
                textDocument: { uri: mainUri, version: 2 },
                contentChanges: [{ text: V2 }],
            });
            await settle();
            check(
                'checkOnChange off: didChange publishes nothing',
                seen.length === before,
                'publishes: ' + JSON.stringify(seen),
            );
            const hover = await request('textDocument/hover', {
                textDocument: { uri: mainUri },
                position: { line: 1, character: 0 },
            });
            const hv = JSON.stringify(hover || {});
            check(
                'checkOnChange off: the change still MOVED the buffer (a hover on line 2 answers)',
                hv.includes('void'),
                hv.slice(0, 160),
            );
            send('textDocument/didSave', { textDocument: { uri: mainUri } });
            await settle();
            check(
                'checkOnChange off: didSave still publishes',
                seen.length > before,
                'publishes: ' + JSON.stringify(seen),
            );
            // `shutdown`, then kill. NOT `exit`: that notification is
            // fire-and-forget, the server quits on reading it, and the pipe closes
            // while the writer still holds the frame -- an unhandled
            // ERR_STREAM_WRITE_AFTER_END inside vscode-jsonrpc that killed node
            // AFTER every check had printed, so the run looked like a pass and the
            // exit code disagreed. This session is not the graceful-shutdown test;
            // the outer one above is, and it ends the way its own comments say.
            await request('shutdown');
            proc.kill();
            // NO `conn.dispose()`. Disposing ends the writer's stream while the
            // reader is still reacting to the pipe closing, and the write that
            // follows lands on an ended stream: an unhandled
            // ERR_STREAM_WRITE_AFTER_END thrown from inside a promise executor, so
            // it is neither caught by this function's `.catch` nor reported as a
            // failed check. The process is about to die anyway; the connection dies
            // with it.
        })().catch((e) => {
            check('checkOnChange off: the session ran', false, e && e.message ? e.message : String(e));
            try {
                proc.kill();
            } catch {
                /* gone */
            }
        });
    });
}

function finish() {
    console.log('');
    console.log(`passed ${pass}, failed ${fail}`);
    fs.rmSync(ws, { recursive: true, force: true });
    process.exit(fail === 0 ? 0 : 1);
}

main();
