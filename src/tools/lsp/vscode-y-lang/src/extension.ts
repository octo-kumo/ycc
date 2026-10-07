// extension.ts -- the VS Code side of the Y language server.
//
// Almost everything here is plumbing that vscode-languageclient already does:
// it speaks JSON-RPC with Content-Length framing, owns request correlation,
// cancellation and the initialize handshake, and registers providers for the
// features the server advertises. What this file adds is the four things it
// cannot:
//
//   1. FINDING yserve (client.ts) -- a Y program built by `make yserve`, not an
//      npm dependency, so there is no node_modules path to resolve.
//   2. STARTING it, with the workspace root.
//   3. REPORTING its death. The server forks a child per message precisely
//      because the compiler calls exit(1) on ordinary input (LSP.md §4.1); but
//      the server process itself can still die, and a client that silently stops
//      checking is worse than one that says so.
//   4. SUPERVISING it -- one automatic restart, then the user is asked. An
//      infinite restart loop against a binary that cannot start is just a fork
//      bomb with a progress bar.
//
// Diagnostics and formatting need no code at all: the client registers them from
// the server's advertised capabilities. Semantic tokens (M2), hover, definition
// and completion (M4) are gated on the same advertisement, so a request is never
// sent for something this server does not implement -- which would be a stream of
// MethodNotFound errors in the log rather than a working feature.

import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
    RevealOutputChannelOn,
} from 'vscode-languageclient/node';

import { config, findServer, notFoundMessage, serverArgs, workspaceRoot } from './client';

let client: LanguageClient | undefined;
let output: vscode.OutputChannel;
let status: vscode.StatusBarItem;
let starting = false;

// ── the heartbeat ──────────────────────────────────────────────────────────
//
// WHY THIS EXISTS. The server's own log is unambiguous: across a 43 second window
// it spent 0.203s working and 43.055s parked in read_frame, so VS Code sent it
// almost nothing. Uninstalling the extension makes the freeze go. Both true, and
// together they only narrow the answer to "the extension host or VS Code proper" --
// and that fork decides everything after it.
//
// The heartbeat is what decides it, from this side. It is a timer on the extension
// host that says how long since the last message from yserve. If it keeps ticking
// on schedule during a freeze, the extension host was responsive the whole time and
// the time went into VS Code's main thread, which nothing in this extension can
// reach. If it falls behind, the extension host was blocked and the cost is here.
//
// So: a delayed heartbeat is evidence, and silence would not have been.
// How far behind schedule this timer is running.
//
// That number IS the measurement, and it needs no plumbing: a timer on a busy
// event loop fires late by exactly the time the loop was blocked. So during a
// freeze, the drift says whether the EXTENSION HOST was blocked or merely idle.
// Drift near zero means the host was responsive throughout and the time went into
// VS Code's main thread instead -- which is outside anything this extension can
// reach, and is the single fork that decides where to look next.
//
// Which is why this is a heartbeat and not more instrumentation of the client's
// own work: the client's own work is already logged, and it was silent through
// every freeze. Silence from a thread you cannot instrument is not evidence, but a
// late timer is.
const HEARTBEAT_MS = 5000;
let heartbeat: ReturnType<typeof setInterval> | undefined;
let lastTick = 0;
let tickCount = 0;

function startHeartbeat(): void {
    stopHeartbeat();
    lastTick = Date.now();
    tickCount = 0;
    heartbeat = setInterval(() => {
        const now = Date.now();
        const drift = now - lastTick - HEARTBEAT_MS;
        lastTick = now;
        tickCount += 1;
        // Only report drift worth acting on, and every tenth clean tick so a long
        // quiet session is visible without a line every five seconds.
        if (drift > 250 || tickCount % 10 === 0) {
            log(`heartbeat ${tickCount}`
                + `  ${(drift / 1000).toFixed(2)}s behind schedule`
                + `  (${(tickCount * HEARTBEAT_MS / 1000 / 60).toFixed(1)}min uptime)`);
        }
    }, HEARTBEAT_MS);
}

function stopHeartbeat(): void {
    if (heartbeat !== undefined) {
        clearInterval(heartbeat);
        heartbeat = undefined;
    }
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    // The FIRST line, before anything else can fail. Without it, "the extension
    // did not activate" and "it activated and then hung" are the same silence.
    activatedAt = Date.now();
    output = vscode.window.createOutputChannel('Y');
    context.subscriptions.push(output);
    const ext = vscode.extensions.getExtension('yun.y-lang');
    log(`activate: entry  ext ${vscode.version}  node ${process.versions.node}`
        + `  activationKind ${ext?.isActive === true ? 'already' : 'onLanguage:y'}`
        + `  folders ${vscode.workspace.workspaceFolders?.length ?? 0}`);

    status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0);
    status.command = 'y.restartLanguageServer';
    context.subscriptions.push(status);

    context.subscriptions.push(
        vscode.commands.registerCommand('y.showServerOutput', () => output.show(true)),
        vscode.commands.registerCommand('y.restartLanguageServer', async () => {
            await restart(context, 'restarted by request');
        }),
        // Format Document is registered automatically from the server's
        // capability, so this command is not about making that work -- it is
        // about being FINDABLE. "No formatter available" and a Format Document
        // that silently does nothing are the two reports this exists to prevent,
        // and a palette entry with a name is the difference.
        vscode.commands.registerCommand('y.formatDocument', async () => {
            const editor = vscode.window.activeTextEditor;
            if (!editor) {
                return;
            }
            await vscode.commands.executeCommand('editor.action.formatDocument');
        }),
    );

    await start(context, 'activated');
}

export async function deactivate(): Promise<void> {
    const c = client;
    client = undefined;
    const t0 = Date.now();
    log(`deactivate: entered (alive for ${sinceActivation()}ms, client ${client ? 'up' : 'never started'})`);
    stopHeartbeat();
    if (c) {
        // stop() sends shutdown + exit and waits. A server that has already died
        // rejects here; that is not worth reporting during deactivate.
        try {
            await c.stop();
            log('deactivate: the language client stopped cleanly');
        } catch (err) {
            log(`deactivate: stop() rejected, which means the server was already gone: ${err}`);
        }
    }
    stopHeartbeat();
    log(`deactivate: done in ${Date.now() - t0}ms`);
}

async function start(context: vscode.ExtensionContext, why: string): Promise<void> {
    if (starting) {
        log('start() called while a start is already in flight -- ignored');
        return;
    }
    starting = true;
    const t0 = Date.now();
    // Entry, before anything can fail: "the extension did not activate" and "it
    // activated and then hung" look identical from outside, and only the first
    // line here tells them apart.
    log(`start(${why})  ext ${vscode.version}  node ${process.versions.node}`);
    try {
        const cfg = config();
        const bin = findServer({
            configured: cfg.serverPath,
            extensionDir: context.extensionPath,
            workspaceRoot: workspaceRoot(),
        });
        if (!bin) {
            // Not an error dialog on every keystroke: once per session, and the
            // message says what to do about it.
            const go = await vscode.window.showErrorMessage(
                notFoundMessage({
                    configured: cfg.serverPath,
                    extensionDir: context.extensionPath,
                    workspaceRoot: workspaceRoot(),
                }),
                'Open settings',
            );
            if (go === 'Open settings') {
                await vscode.commands.executeCommand('workbench.action.openSettings', 'y.lsp.serverPath');
            }
            setStatus('$(warning) Y: no server', 'yserve was not found');
            log('no server binary -- nothing was started');
            return;
        }

        const root = workspaceRoot();
        log(`resolved  server=${bin}  root=${root}  warnings=${cfg.warnings}`
            + `  checkOnChange=${cfg.checkOnChange}  timing=${cfg.timing}`
            + `  trace=${cfg.trace}`);
        log(`argv      ${serverArgs(root, cfg.warnings).join(' ')}`);

        const server: ServerOptions = {
            run: { command: bin, args: serverArgs(root, cfg.warnings), transport: TransportKind.stdio },
            debug: { command: bin, args: serverArgs(root, cfg.warnings), transport: TransportKind.stdio },
        };

        const clientOptions: LanguageClientOptions = {
            documentSelector: [{ scheme: 'file', language: 'y' }],
            outputChannel: output,
            // The server prints compiler output (an import it could not open, a
            // trap message) to stderr. Those lines are the only explanation a
            // user gets for a missing squiggle, so they belong in the channel
            // the Output menu points at.
            revealOutputChannelOn: RevealOutputChannelOn.Never,
            // R1.8. `rootPath` here is redundant -- it also goes on argv as
            // `--root` (see serverArgs), which is where yserve reads it -- and it
            // is left in place rather than removed, because a client sending an
            // option the server ignores is harmless and removing it would churn
            // the wire for nothing. `checkOnChange` is NOT redundant: argv has no
            // place for it, and without initializationOptions there was nowhere
            // for the server to read it at all.
            initializationOptions: {
                rootPath: root ?? null,
                checkOnChange: cfg.checkOnChange,
                // Per-request timing lines in the Y output channel. On by default,
                // off with y.lsp.timing: false. They are the only way to see whether
                // the server or the editor is the slow side, so they are worth two
                // appendLine calls on the extension host, and it should be the user's
                // call to turn them off rather than mine to remove them.
                timing: cfg.timing,
            },
        };

        const c = new LanguageClient('y', 'Y Language Server', server, clientOptions);
        client = c;

        // The client's state goes Stopped -> Starting -> Running even on a
        // successful start, so reacting to every Stopped would put "server
        // stopped" in the status bar for the moment before "running". Only
        // report it once we have actually been running -- otherwise a successful
        // start begins by showing the user an error.
        // vscode-languageclient's State enum, from lib/common/client.d.ts:
        // Stopped = 1, Starting = 2, Running = 3. The enum is not re-exported from
        // the package root, so it is written out here -- and it was written out
        // WRONG before this: `3 /* Stopped */` and `3 - 1 /* Running */`. Those are
        // Running and Starting. So the branch that reports a dead server was keyed
        // on Running (where `everStarted` is false, so it did nothing) and the real
        // Stopped, 1, matched neither: the status bar NEVER said the server had
        // stopped. A user log caught it -- `client state: 3` followed by
        // `client state: 2` reads as backwards, and it was.
        const LSTATE_STOPPED = 1;
        const LSTATE_RUNNING = 3;
        const stateName = (n: number) =>
            n === 1 ? 'Stopped' : n === 2 ? 'Starting' : n === 3 ? 'Running' : `${n}?`;

        let everStarted = false;
        c.onDidChangeState((e) => {
            // With the elapsed time, because a slow start is the thing worth seeing,
            // and with the NAME: a bare integer is what made the wrong constants
            // above survive this long.
            log(`client state: ${stateName(e.newState)} (${e.newState})`
                + `  (+${sinceActivation()}ms since activation)`);
            if (e.newState === LSTATE_RUNNING) {
                everStarted = true;
            } else if (e.newState === LSTATE_STOPPED && everStarted) {
                setStatus('$(error) Y: server stopped', 'the language server is not running');
                log('the server stopped after running -- the status bar now says so');
            }
        });
        log('handing the server process to the language client');

        await c.start();
        setStatus('$(check) Y', 'the Y language server is running');
        log(`started and running  (${Date.now() - t0}ms in start())`);
        registerOptionalProviders(c);
        log('optional providers registered; activate() returning');
        startHeartbeat();
    } catch (err) {
        log(`start(${why}) FAILED after ${Date.now() - t0}ms: ${err}`);
        const message = err instanceof Error ? err.message : String(err);
        log(`failed to start: ${message}`);
        setStatus('$(error) Y: server failed', message);
        output.show(true);
    } finally {
        starting = false;
    }
}

async function restart(context: vscode.ExtensionContext, why: string): Promise<void> {
    const c = client;
    client = undefined;
    if (c) {
        try {
            await c.stop();
        } catch {
            /* already gone */
        }
    }
    await start(context, why);
}

/**
 * Providers for the features this server may not have yet.
 *
 * The gate is the server's OWN advertised capabilities, read after initialize.
 * Registering a provider the server does not implement is not a no-op: the
 * client sends the request on every hover and every completion, and the server
 * answers MethodNotFound each time. So `yhoverProvider: true` without a
 * handler is the difference between "no hover yet" and a log full of errors.
 */
function registerOptionalProviders(c: LanguageClient): void {
    const caps = c.initializeResult?.capabilities as
        | {
              semanticTokensProvider?: unknown;
              hoverProvider?: unknown;
              definitionProvider?: unknown;
              completionProvider?: unknown;
          }
        | undefined;
    if (!caps) {
        return;
    }
    // Diagnostics, formatting, semantic tokens and the outline are ALL
    // registered by the client library from the capabilities above, so there is
    // nothing to write here for M1, M2 or M3. That is the whole reason those
    // features cost a few hundred lines of Y and no TypeScript at all.
    //
    // Worth knowing, because it looks like a trap: the server sends semantic
    // tokens as INDICES, so a client-side legend that disagreed would paint every
    // token after the first difference as the wrong kind, silently. There is no
    // such disagreement available here --
    // `asSemanticTokensLegend(options.legend)` in the library builds the VS Code
    // legend FROM the server's advertised one. So the legend is defined once, in
    // src/tools/lsp/sem.y, and adding a client-side copy would be wrong, not
    // merely redundant.
    // hover, definition and completion (M4) each need a handler that maps server
    // shapes onto VS Code enums. They are NOT advertised, so nothing is requested
    // and nothing fails; the gate is here so the wiring lands in one place.
    void caps.hoverProvider;
    void caps.definitionProvider;
    void caps.completionProvider;
}

function setStatus(text: string, tooltip: string): void {
    status.text = text;
    status.tooltip = `Y language server: ${tooltip}`;
    status.show();
}

/** `[hh:mm:ss.mmm] Y-client  ...` -- which side of the socket said it.
 *
 *  The server writes its own lines prefixed `yserve:` and they land in this same
 *  channel, so an unmarked line was ambiguous: it was not obvious whether
 *  "starting ..." came from here or from there. Every line here is the extension.
 */
function log(msg: string): void {
    const t = new Date().toISOString().slice(11, 23);
    output.appendLine(`[${t}] Y-client  ${msg}`);
}

/** The extension host can be busy for a long time; these say how long. */
let activatedAt = 0;
const sinceActivation = () => (activatedAt === 0 ? 0 : Date.now() - activatedAt);
