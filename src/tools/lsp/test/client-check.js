// client-check.js -- drive yserve with the SAME JSON-RPC library VS Code uses.
//
// The python driver in test-e2e.sh speaks the protocol by hand, which proves the
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
                semanticTokens: {
                    requests: { full: true, range: false },
                    tokenTypes: [],
                    tokenModifiers: [],
                    formats: ['relative'],
                },
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
            'initialize: advertises exactly the seven capabilities it implements',
            advertised.sort().join(',') ===
                'completionProvider,definitionProvider,documentFormattingProvider,' +
                    'documentSymbolProvider,hoverProvider,semanticTokensProvider,textDocumentSync',
            'advertised: ' + advertised.sort().join(','),
        );
        // The legend is a wire format shared with the highlighter: the client
        // sends these names back and uses the INDICES, so a mismatch paints every
        // token after the first difference as the wrong kind, silently.
        const leg = init.capabilities.semanticTokensProvider && init.capabilities.semanticTokensProvider.legend;
        check(
            'initialize: the semantic token legend is present and ordered',
            // The five SEMANTIC classes are in the legend now (R2.3), appended so
            // the eight before them keep their wire indices -- an editor's theme is
            // keyed on those. The length was 9 and the check said so literally, so
            // the day the classes landed this read as "the legend is broken".
            !!leg && Array.isArray(leg.tokenTypes) && leg.tokenTypes.length === 14 &&
                leg.tokenTypes[0] === 'comment' && leg.tokenTypes[8] === 'error' &&
                leg.tokenTypes[9] === 'parameter' && leg.tokenTypes[10] === 'function' &&
                leg.tokenTypes[11] === 'property' && leg.tokenTypes[12] === 'type' &&
                leg.tokenTypes[13] === 'builtin',
            JSON.stringify(leg && leg.tokenTypes),
        );
        // Every advertised token type must either be one VS Code already knows how
        // to colour, or be DECLARED in package.json with a superType.
        //
        // This is not a style preference. VS Code's built-in fallback covers the
        // LSP's standard type names; anything outside that list gets NO colour from
        // any shipped theme unless the extension declares it. `builtin` was one of
        // four such names here, so `print`, `len` and `clock_us` rendered as plain
        // foreground -- the user reported it as "builtins are still white", which
        // is exactly what it was. Declaring them is theme-independent: VS Code
        // scores a theme rule against the type's superType chain, so an exact rule
        // still wins and the superType is only the fallback.
        const LSP_STANDARD = new Set([
            'namespace', 'class', 'enum', 'interface', 'struct', 'typeParameter',
            'type', 'parameter', 'variable', 'property', 'enumMember', 'decorator',
            'event', 'function', 'method', 'macro', 'label', 'comment', 'string',
            'keyword', 'number', 'regexp', 'operator',
        ]);
        const declaredTypes = new Map(
            (((pkgExt.contributes || {}).semanticTokenTypes) || []).map((t) => [t.id, t.superType]));
        const undeclared = (leg && leg.tokenTypes ? leg.tokenTypes : [])
            .filter((t) => !LSP_STANDARD.has(t) && !declaredTypes.has(t));
        check(
            'initialize: every token type is either standard or declared with a superType',
            undeclared.length === 0,
            'no colour from any theme: ' + undeclared.join(','),
        );
        // And a declared superType must itself be a real type, or the chain dead-ends
        // and the token is uncoloured again -- which is the same bug wearing a
        // different hat.
        const badParents = [...declaredTypes.entries()].filter(
            ([, parent]) => !LSP_STANDARD.has(parent) && !declaredTypes.has(parent));
        check(
            'package.json: every declared superType resolves to a real token type',
            badParents.length === 0,
            'dangling: ' + badParents.map(([id, p2]) => id + '->' + p2).join(','),
        );
        // AND a colour, so a type can never be shipped uncoloured again.
        //
        // superType alone was tried and did not put a colour on screen: `builtin`
        // stayed plain foreground after the manifest shipped it, twice. The
        // mechanism is right in the code -- VS Code scores both theme rules and its
        // own default rules through `getTypeHierarchy(n).indexOf(o.type)`, so a
        // superType does reach the parent -- but a manifest that can only be
        // checked by reading is a manifest that cannot be trusted to have been
        // applied. So the four also carry an explicit default colour, and this
        // asserts it, which means the day one is dropped the suite says so.
        const cfgDefaults = (pkgExt.contributes || {}).configurationDefaults || {};
        const uncoloured = (leg && leg.tokenTypes ? leg.tokenTypes : [])
            .filter((t) => !LSP_STANDARD.has(t)
                && cfgDefaults['editor.semanticTokenTypes.' + t] === undefined
                && !declaredTypes.has(t));
        check(
            'package.json: every token type has a colour -- a default or a superType',
            uncoloured.length === 0,
            'nothing paints these: ' + uncoloured.join(','),
        );
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

        // 5b. SEMANTIC TOKENS: the request a highlighter makes on every visible
        //     change, and the one place a bad delta shows up as a whole file
        //     painted in the wrong colours rather than as an error.
        // The lines of what is CURRENTLY open -- which is `messy`, put there by
        // step 4's didChange, not the original `text`. Checking the tokens
        // against the wrong document's line lengths is how this first reported
        // five tokens "outside" a document they were all inside.
        const lines = messy.split('\n');
        const st = await request('textDocument/semanticTokens/full', { textDocument: { uri: mainUri } });
        const data = st && st.data;
        check('semanticTokens: an array of numbers', Array.isArray(data) && data.length % 5 === 0,
            'length ' + (data ? data.length : 'none'));
        // Decoded exactly as an editor decodes it: five numbers per token,
        // deltaLine against the previous token's line, deltaStartChar against its
        // start only when they share a line.
        let pl = 0, pc = 0, pend = -1, bad = 0, outside = 0;
        for (let i = 0; i + 4 < data.length; i += 5) {
            const dl = data[i], dc = data[i + 1], len = data[i + 2];
            const line = pl + dl;
            const ch = dl === 0 ? pc + dc : dc;
            if (len <= 0 || line < 0 || ch < 0) { bad++; }
            if (line >= lines.length) { outside++; }
            else if (ch + len > lines[line].length + 1) { outside++; }
            if (pend >= 0 && line * 1000000 + ch < pend) { bad++; }
            pend = line * 1000000 + ch + len;
            pl = line;
            pc = ch;
        }
        check('semanticTokens: every token positive-length, ordered, non-overlapping', bad === 0,
            bad + ' bad of ' + (data.length / 5));
        check('semanticTokens: every token inside the document', outside === 0,
            outside + ' outside, ' + (data.length / 5) + ' tokens over ' + lines.length + ' lines');
        check('semanticTokens: the file produced a plausible number of tokens',
            data.length > 40, data.length + ' numbers for ' + lines.length + ' lines');

        // What a name DENOTES (R2.3). The five semantic classes are resolved by the
        // server's own index and the compiler's own builtin list -- never guessed --
        // so each is checked by NAME through the legend, which is the only thing a
        // client ever sees.
        const semText = [
            'type Pair = { a: long, b: long };',        // 0
            'def twice(n: long) -> long {',               // 1
            '    let inner = n * 2;',                     // 2
            '    inner',                                  // 3
            '}',                                          // 4
            'let p: Pair = { a: 1, b: 2 };',              // 5
            'let q = p.a;',                               // 6
            'print(twice(p.a));',                         // 7
            'let z = nosuchthing;',                       // 8
        ].join('\n');
        send('textDocument/didChange', {
            textDocument: { uri: mainUri, version: 12 },
            contentChanges: [{ text: semText }],
        });
        await settle();
        const semToks = await request('textDocument/semanticTokens/full', { textDocument: { uri: mainUri } });
        const semData = semToks && semToks.data;
        const names = leg.tokenTypes;
        const semLines = semText.split('\n');
        // The class of the first identifier at (line, needle), by legend NAME.
        // Decoded the way an editor decodes it. `pc` is the previous token's START
        // and it is not optional: deltaStartChar is relative to it when two tokens
        // share a line and absolute otherwise, so a decoder that keeps only `dc`
        // silently reads every second token on a line from the wrong place. It is
        // the first thing t010_sem's own decode gets right and the thing this one
        // got wrong, which showed up as two cases answering `no-token` for a
        // parameter and a property that are both there.
        const classOf = (line, needle) => {
            const at = semLines[line].indexOf(needle);
            if (at < 0) { return 'NO-SUCH-COLUMN'; }
            let pl = 0, pc = 0;
            for (let i = 0; i + 4 < semData.length; i += 5) {
                const dl = semData[i];
                const line2 = pl + dl;
                const ch = dl === 0 ? pc + semData[i + 1] : semData[i + 1];
                const len = semData[i + 2];
                if (line2 === line && at >= ch && at < ch + len) {
                    const t = semData[i + 3];
                    return t >= 0 && t < names.length ? names[t] : 'type' + t;
                }
                pl = line2;
                pc = ch;
            }
            return 'no-token';
        };
        check('semantic classes: a type alias is a type', classOf(0, 'Pair') === 'type', classOf(0, 'Pair'));
        check('semantic classes: a def is a function', classOf(1, 'twice') === 'function', classOf(1, 'twice'));
        check('semantic classes: a parameter is a parameter', classOf(1, 'n:') === 'parameter', classOf(1, 'n:'));
        check('semantic classes: a member after a dot is a property', classOf(6, 'a;') === 'property', classOf(6, 'a;'));
        check('semantic classes: a builtin is a builtin', classOf(7, 'print') === 'builtin', classOf(7, 'print'));
        check('semantic classes: an ordinary let stays a variable', classOf(3, 'inner') === 'variable', classOf(3, 'inner'));
        // And the one that matters most: a name nothing declares must NOT get a
        // class it did not earn, or an editor paints a typo as real code.
        check('semantic classes: a name nothing declares stays a variable',
            classOf(8, 'nosuchthing') === 'variable', classOf(8, 'nosuchthing'));
        // A multi-line comment must be SEVERAL tokens: one token crossing a line
        // break paints from its start to the end of the file, and the result looks
        // like a broken theme rather than a broken server.
        send('textDocument/didChange', {
            textDocument: { uri: mainUri, version: 9 },
            contentChanges: [{ text: '/* one\n   two\n   three */\nlet x = 1;\n' }],
        });
        await settle();
        const stC = await request('textDocument/semanticTokens/full', { textDocument: { uri: mainUri } });
        let commentLines = 0;
        {
            let l2 = 0, c2 = 0;
            for (let i = 0; i + 4 < stC.data.length; i += 5) {
                const line = l2 + stC.data[i];
                const ch = stC.data[i] === 0 ? c2 + stC.data[i + 1] : stC.data[i + 1];
                if (stC.data[i + 3] === 0) { commentLines++; }   // 0 == comment
                l2 = line;
                c2 = ch;
            }
        }
        check('semanticTokens: a 3-line block comment is 3 tokens, not 1', commentLines === 3,
            commentLines + ' comment tokens');
        // A buffer that does not lex must still highlight (R2.5).
        send('textDocument/didChange', {
            textDocument: { uri: mainUri, version: 10 },
            contentChanges: [{ text: 'let s = "oops\nlet y = 1;\n' }],
        });
        await settle();
        const stBroken = await request('textDocument/semanticTokens/full', { textDocument: { uri: mainUri } });
        check('semanticTokens: a buffer that does not lex still returns tokens',
            Array.isArray(stBroken.data) && stBroken.data.length > 0,
            'length ' + (stBroken && stBroken.data && stBroken.data.length));
        send('textDocument/didChange', {
            textDocument: { uri: mainUri, version: 11 },
            contentChanges: [{ text: text }],
        });
        await settle();

        // 5c. DOCUMENT SYMBOLS: the outline. "no symbols found in document" is
        //     exactly what an editor says when this comes back empty.
        // ── M4: hover, definition, completion ──
        // `print(f() + helper.f());` is the LAST line, which is line 7 -- line 1
        // of the fixture is blank. `f` is the local def on line 2; `helper` is an
        // import on line 0, and Stage A honestly answers null for it, because the
        // name belongs to another file and this is not the compiler's scope.
        const at = (l, c) => ({ textDocument: { uri: mainUri }, position: { line: l, character: c } });
        const lineOf = (t) => text.split('\n')[t];
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
