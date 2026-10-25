// vscode-stub.js -- enough of the `vscode` module to run an extension's
// activate() outside VS Code.
//
// The shape of this file is the whole idea. A stub that returns undefined for
// anything it does not model produces failures that look like bugs in the
// extension ("x is not a function" three frames deep in somebody else's
// library). So the fallback here answers unknown names with a CLASS: truthy, so
// a feature-registration check passes, and usable as a base class, so
// `class X extends vscode.Whatever` compiles. Every entry below was added
// because vscode-languageclient's registration path actually needed it, and each
// says why -- so the next person does not delete one as redundant.
//
// What is stubbed for real: the handful of things extension.ts calls, plus the
// four that vscode-languageclient subscribes to during registration.
// activate-check.js reads __calls, __lines, __status and __messages.

'use strict';

const calls = [];
const lines = [];
const status = [];
const messages = [];

function reset() {
    calls.length = 0;
    lines.length = 0;
    status.length = 0;
    messages.length = 0;
}

const disposable = { dispose: () => undefined };

// A DocumentSelector is a string or {language, scheme}; the client library
// passes one of those to every register*, and the tests want to see WHICH
// language a provider was registered for -- a provider registered for nothing
// is a provider that never fires.
const sel_lang = (sel) => {
    if (typeof sel === 'string') return sel;
    if (sel && typeof sel.language === 'string') return sel.language;
    if (Array.isArray(sel) && sel.length > 0) return sel_lang(sel[0]);
    return '?';
};

/** An event registration: records that it happened, returns a disposable. */
const evt = (name) => (listener) => {
    calls.push('sub:' + name);
    return disposable;
};

class Placeholder {
    constructor(...args) {
        this.args = args;
    }
}

// A real EventEmitter. The library builds one per feature and calls its `.event`
// to subscribe; a placeholder class here fails as
// "onPendingChangeAdded is not a function", which reads like an extension bug.
class EventEmitter {
    constructor() {
        this._ls = [];
        this.event = (listener) => {
            this._ls.push(listener);
            return disposable;
        };
    }
    fire(e) {
        this._ls.forEach((l) => {
            try {
                l(e);
            } catch {
                /* a listener throwing is not this file's business */
            }
        });
    }
    dispose() {
        this._ls = [];
    }
}

// Disposable.from(...) is called with a spread. `new this(...)` rather than
// `new Disposable(...)`, because a subclass calling the inherited static would
// otherwise hit a ReferenceError from the class's own scope.
class Disposable {
    constructor(fn) {
        this._fn = fn;
    }
    static from(...items) {
        return new this(() => items.forEach((i) => i && i.dispose && i.dispose()));
    }
    dispose() {
        if (this._fn) {
            this._fn();
        }
    }
}

class Range {
    constructor(a, b, c, d) {
        Object.assign(this, { a, b, c, d });
    }
}
class Position {
    constructor(line, character) {
        this.line = line;
        this.character = character;
    }
}

const config = {
    // activation-check.js sets this to simulate a user-configured serverPath.
    __override: undefined,
    get(section) {
        return {
            get: (key, dflt) => {
                if (config.__override) {
                    return config.__override[key] ?? dflt;
                }
                return dflt;
            },
        };
    },
};

const real = {
    // The library refuses to start without a parseable version. This is the one
    // piece of environment a headless run has to supply honestly.
    version: '1.95.0',
    env: {
        language: 'en',
        machineId: 'test-machine',
        sessionId: 'test-session',
        uiKind: 1,
        appName: 'vscode-stub',
        appRoot: '/',
        isNewAppInstall: false,
    },

    window: {
        // `append` as well as `appendLine`: the language client writes the server's
        // stderr through `outputChannel.append`, once per CHUNK it reads, so a stub
        // with only appendLine throws "append is not a function" the moment the
        // server says anything -- which is exactly when the activation check most
        // wants to be watching. A chunk can carry several lines, so append splits on
        // newlines and records each: the checks below count lines, not chunks.
        createOutputChannel: (name) => ({
            name,
            appendLine: (m) => lines.push(String(m)),
            append: (m) => {
                for (const one of String(m).split('\n')) {
                    if (one.length > 0) { lines.push(one); }
                }
            },
            show: () => calls.push('output.show'),
            dispose: () => undefined,
        }),
        // The text is RECORDED: "the server is not running" and "the server is
        // running" are the only two things a user can see when the extension
        // cannot start, so whether that text is ever set is worth asserting on.
        createStatusBarItem: () => ({
            show: () => undefined,
            hide: () => undefined,
            dispose: () => undefined,
            set text(t) {
                status.push(String(t));
            },
            get text() {
                return '';
            },
        }),
        showErrorMessage: async (m) => {
            messages.push(String(m));
            return 'Open settings';
        },
        showWarningMessage: async (m) => {
            messages.push(String(m));
            return undefined;
        },
        showInformationMessage: async (m) => {
            messages.push(String(m));
            return undefined;
        },
        // vscode-languageclient walks every open TAB when it registers the
        // diagnostic collection. An empty list is the honest answer here: no
        // tabs are open in a headless run.
        tabGroups: { all: [], close: async () => true, onDidChangeTabs: evt('onDidChangeTabs') },
        onDidChangeActiveTextEditor: evt('onDidChangeActiveTextEditor'),
        onDidChangeVisibleTextEditors: evt('onDidChangeVisibleTextEditors'),
        onDidChangeTextEditorSelection: evt('onDidChangeTextEditorSelection'),
        onDidChangeActiveColorTheme: evt('onDidChangeActiveColorTheme'),
        activeTextEditor: undefined,
        visibleTextEditors: [],
    },

    // `extensions.getExtension`, because activate() asks whether this extension is
    // already active in order to say WHY it is activating, and a stub without it
    // throws on the very first line of activate() -- before anything under test.
    extensions: {
        getExtension: (id) => (id === 'yun.y-lang' ? { id, isActive: false } : undefined),
    },
    workspace: {
        getConfiguration: (section) => config.get(section),
        workspaceFolders: undefined,
        // The document events. Each is a real function because the library tests
        // for their existence before registering its feature, and the fallback
        // (a class) is truthy -- so without these it would register a feature it
        // then cannot drive.
        onDidChangeTextDocument: evt('onDidChangeTextDocument'),
        onDidOpenTextDocument: evt('onDidOpenTextDocument'),
        onDidCloseTextDocument: evt('onDidCloseTextDocument'),
        onDidSaveTextDocument: evt('onDidSaveTextDocument'),
        onWillSaveTextDocument: evt('onWillSaveTextDocument'),
        onDidChangeConfiguration: evt('onDidChangeConfiguration'),
        onDidChangeWorkspaceFolders: evt('onDidChangeWorkspaceFolders'),
        textDocument: {},
        // An empty open-document set: the did-open feature iterates it on
        // registration, so it must be an array rather than a placeholder.
        textDocuments: [],
    },

    languages: {
        // Every register* the client library calls while registering a feature.
        // The list is deliberately wider than the features this server
        // implements, and it has had to be widened TWICE for the same reason:
        // activation-check.js found the gap the moment the server started
        // advertising documentSymbolProvider and the library asked for a function
        // the stub did not have, and again when M4 added definitionProvider,
        // hoverProvider and completionProvider. The failure reads as "the
        // extension cannot start", which is the worst possible way to learn that
        // a STUB is incomplete -- and it points at the extension rather than at
        // the stub, so it costs a while to see.
        //
        // Each records the selector it was given, so activation-check can assert
        // that the three M4 providers were really registered rather than only
        // that nothing threw.
        registerDefinitionProvider: (sel) => {
            calls.push('register:DefinitionProvider(' + sel_lang(sel) + ')');
            return disposable;
        },
        registerHoverProvider: (sel) => {
            calls.push('register:HoverProvider(' + sel_lang(sel) + ')');
            return disposable;
        },
        // The trigger characters are VARARGS, not an array:
        // registerCompletionItemProvider(selector, provider, ...triggerCharacters).
        // Reading rest[0] as an array made every run report "none" and would have
        // hidden a server that stopped sending them.
        registerCompletionItemProvider: (sel, provider, ...rest) => {
            calls.push('register:CompletionItemProvider(' + sel_lang(sel) + ',' +
                (rest.length > 0 ? rest.join('') : 'none') + ')');
            return disposable;
        },
        registerDocumentSymbolProvider: () => disposable,
        registerDocumentRangeSemanticTokensProvider: () => disposable,
        registerReferenceProvider: () => disposable,
        registerSignatureHelpProvider: () => disposable,
        registerRenameProvider: () => disposable,
        registerCodeActionsProvider: () => disposable,
        registerWorkspaceSymbolProvider: () => disposable,
        registerDocumentHighlightProvider: () => disposable,
        registerDocumentLinkProvider: () => disposable,
        registerInlayHintsProvider: () => disposable,
        registerImplementationProvider: () => disposable,
        registerTypeDefinitionProvider: () => disposable,
        registerDeclarationProvider: () => disposable,
        registerFoldingRangeProvider: () => disposable,
        registerSelectionRangeProvider: () => disposable,
        registerCallHierarchyProvider: () => disposable,
        registerTypeHierarchyProvider: () => disposable,
        registerWorkspaceSymbolResolveProvider: () => disposable,
        match: () => 0,
        setLanguageConfiguration: () => disposable,
        getDiagnostics: () => [],
        createDiagnosticCollection: () => ({
            set: () => calls.push('diagnostics.set'),
            clear: () => calls.push('diagnostics.clear'),
            dispose: () => undefined,
        }),
        registerDocumentFormattingEditProvider: () => disposable,
        registerDocumentSemanticTokensProvider: () => disposable,
        // The hover and completion registrations used to be repeated HERE, as
        // bare no-ops, and a duplicate key in one object literal is not a merge:
        // the later one wins silently. So the recording versions added above
        // were dead, `definitionProvider` (which had no duplicate) was the only
        // one the tests could see, and activation-check reported a set of three
        // registrations for a server that registers six. Removed, not overridden.
        registerCodeLensProvider: () => disposable,
        createDiagnosticCollection: () => ({
            set: () => calls.push('diagnostics.set'),
            clear: () => calls.push('diagnostics.clear'),
            dispose: () => undefined,
        }),
        getDiagnostics: () => [],
        match: () => 0,
    },

    commands: {
        registerCommand: (name) => {
            calls.push('register:' + name);
            return disposable;
        },
        executeCommand: async (name) => {
            calls.push('execute:' + name);
            return undefined;
        },
    },

    StatusBarAlignment: { Left: 1, Right: 2 },
    DiagnosticSeverity: { Error: 0, Warning: 1, Information: 2, Hint: 3 },
    Range,
    Position,
    Uri: {
        file: (p) => ({ fsPath: p, scheme: 'file', toString: () => 'file://' + p }),
        parse: (s) => ({ fsPath: String(s).replace(/^file:\/\//, ''), scheme: 'file' }),
    },
    EventEmitter,
    Disposable,
    CancellationTokenSource: class {
        constructor() {
            this.token = { isCancellationRequested: false, onCancellationRequested: evt('cancel') };
        }
        cancel() {
            /* nothing to cancel in a stub */
        }
        dispose() {
            /* nothing held */
        }
    },

    // Classes vscode-languageclient subclasses at load time. The fallback covers
    // them, but naming the ones it touches keeps the failure mode predictable.
    CompletionItem: Placeholder,
    CompletionItemKind: Placeholder,
    CodeAction: Placeholder,
    CodeActionKind: Placeholder,
    DocumentLink: Placeholder,
    Diagnostic: Placeholder,
    DiagnosticRelatedInformation: Placeholder,
    SymbolKind: Placeholder,
    SymbolTag: Placeholder,
    DocumentHighlightKind: Placeholder,
    TextEdit: Placeholder,
    WorkspaceEdit: Placeholder,
    CodeLens: Placeholder,
    InlayHint: Placeholder,
    SemanticTokens: Placeholder,
    SemanticTokensBuilder: Placeholder,
    SemanticTokensLegend: Placeholder,
    DocumentSemanticTokensProvider: Placeholder,
    Hover: Placeholder,
    MarkdownString: Placeholder,
    TabInputText: Placeholder,
    TabInputTextDiff: Placeholder,
    TabInputNotebook: Placeholder,
    TabInputCustom: Placeholder,
    TabInputWebview: Placeholder,
    DocumentSelector: Placeholder,
};

module.exports = new Proxy(real, {
    get(target, prop) {
        if (prop in target) {
            return target[prop];
        }
        if (typeof prop === 'symbol') {
            return undefined;
        }
        return Placeholder;
    },
    has() {
        return true;
    },
});

// The recording surface activate-check.js asserts on.
module.exports.__calls = calls;
module.exports.__lines = lines;
module.exports.__status = status;
module.exports.__messages = messages;
module.exports.__reset = reset;
Object.defineProperty(module.exports, '__config', {
    get: () => config.__override,
    set: (v) => {
        config.__override = v;
    },
});
