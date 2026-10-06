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

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    output = vscode.window.createOutputChannel('Y');
    context.subscriptions.push(output);

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
    if (c) {
        // stop() sends shutdown + exit and waits. A server that has already died
        // rejects here; that is not worth reporting during deactivate.
        try {
            await c.stop();
        } catch {
            /* already gone */
        }
    }
}

async function start(context: vscode.ExtensionContext, why: string): Promise<void> {
    if (starting) {
        return;
    }
    starting = true;
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
            return;
        }

        const root = workspaceRoot();
        log(`starting ${bin} ${serverArgs(root, cfg.warnings).join(' ')} (${why})`);

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
            },
        };

        const c = new LanguageClient('y', 'Y Language Server', server, clientOptions);
        client = c;

        // The client's state goes Stopped -> Starting -> Running even on a
        // successful start, so reacting to every Stopped would put "server
        // stopped" in the status bar for the moment before "running". Only
        // report it once we have actually been running -- otherwise a successful
        // start begins by showing the user an error.
        let everStarted = false;
        c.onDidChangeState((e) => {
            log(`client state: ${e.newState}`);
            if (e.newState === 3 /* Stopped */) {
                if (everStarted) {
                    setStatus('$(error) Y: server stopped', 'the language server is not running');
                }
            } else if (e.newState === 3 - 1 /* Running */) {
                everStarted = true;
            }
        });

        await c.start();
        setStatus('$(check) Y', 'the Y language server is running');
        log('started');
        registerOptionalProviders(c);
    } catch (err) {
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

function log(msg: string): void {
    const t = new Date().toISOString().slice(11, 23);
    output.appendLine(`[${t}] ${msg}`);
}
