// client.ts -- starting, finding and supervising the yserve process.
//
// The whole client is built on vscode-languageclient, which already speaks
// JSON-RPC with Content-Length framing and owns request/response correlation,
// cancellation and the initialize handshake. So this file is only responsible
// for the three things that library cannot do for us:
//
//   1. FINDING the binary. yserve is a Y program built by `make yserve`, not an
//      npm dependency, so there is no node_modules path to resolve. The search
//      order is in findServer().
//   2. STARTING it, with --root.
//   3. NOT DYING QUIETLY. The server's whole design rests on forking a child per
//      message (LSP.md §4.1) because the compiler calls exit(1) on ordinary
//      input. If the server itself dies, the editor must say so: a client that
//      silently stops offering completions is worse than one that says "the
//      language server crashed".

import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

/** Where yserve might be, in the order we look. Each is tried in turn. */
export interface SearchSpec {
    /** `y.lsp.serverPath`, if set. If this is wrong we do not search: an
     *  explicit setting that does not work is a configuration error, and
     *  silently falling back to a different binary would be baffling. */
    configured: string | undefined;
    /** This extension's own directory. */
    extensionDir: string;
    /** The workspace folder, for the repo layout where `make yserve` puts the
     *  binary at the root. */
    workspaceRoot: string | undefined;
}

/** One place we looked. The path is enough: findServer filters by stat, so
 *  there is no "why" to report -- anything that is not runnable is simply not
 *  there as far as the search is concerned, and notFoundMessage lists them all. */
interface Probe {
    path: string;
}

function isExecutableFile(p: string): boolean {
    try {
        const st = fs.statSync(p);
        if (!st.isFile()) {
            return false;
        }
        fs.accessSync(p, fs.constants.X_OK);
        return true;
    } catch {
        return false;
    }
}

/**
 * The candidate paths, in order, with the ones that are not runnable filtered
 * out. Exported so a test can check the ORDER without spawning anything: the
 * order is the part with a judgement in it.
 */
export function candidates(spec: SearchSpec): Probe[] {
    const names = process.platform === 'win32' ? ['yserve.exe'] : ['yserve'];
    const out: Probe[] = [];

    if (spec.configured && spec.configured.length > 0) {
        out.push({ path: spec.configured });
        return out;
    }
    for (const n of names) {
        out.push({ path: path.join(spec.extensionDir, n) });
        out.push({ path: path.join(spec.extensionDir, '..', n) });
        out.push({ path: path.join(spec.extensionDir, '..', '..', '..', n) });
    }
    if (spec.workspaceRoot) {
        for (const n of names) {
            out.push({ path: path.join(spec.workspaceRoot, n) });
            out.push({ path: path.join(spec.workspaceRoot, 'yserve', n) });
        }
    }
    return out;
}

/**
 * The first runnable yserve, or undefined.
 *
 * PATH is deliberately NOT searched here -- the LanguageClient spawns by path,
 * and letting a bare 'yserve' through would mean `spawn` resolving it against
 * PATH and working in the shell but failing in VS Code, or worse, picking up an
 * unrelated binary. If it is on PATH the user sets y.lsp.serverPath.
 */
export function findServer(spec: SearchSpec): string | undefined {
    for (const c of candidates(spec)) {
        if (isExecutableFile(c.path)) {
            return c.path;
        }
    }
    return undefined;
}

/** What to tell the user when no yserve could be found. */
export function notFoundMessage(spec: SearchSpec): string {
    if (spec.configured && spec.configured.length > 0) {
        return (
            `y.lsp.serverPath is set to '${spec.configured}', which is not an executable file. ` +
            `Fix the setting, or clear it to search automatically.`
        );
    }
    const tried = candidates(spec)
        .map((c) => c.path)
        .join('\n  ');
    return (
        `Could not find the yserve binary. Build it with 'make yserve' at the repository root, ` +
        `or set y.lsp.serverPath to its location.\nLooked in:\n  ${tried}`
    );
}

/**
 * The arguments yserve is started with.
 *
 * `warnings` is R1.6, and it is ARGV rather than an initializationOption because
 * `yserve` has always read it that way (`-W` / `--wlevel`): the flag is part of how
 * the compiler is invoked, it is parsed before any state exists, and it changes what
 * `check_program` is asked for rather than how a message is answered. Putting it on
 * argv means the setting needed no server change at all -- which is the whole of
 * that requirement's cost.
 *
 * Off by default, which is `yserve`'s own default and therefore what every user
 * sees today. Note that this is LESS than `ycc`, which warns by default: level 1
 * adds the dropped-value and empty-`else` checks, and a user who wants the editor
 * to agree with the compiler turns this on. Changing the default would change what
 * every existing user sees, which is a decision and not a bug fix.
 */
export function serverArgs(root: string | undefined, warnings?: boolean): string[] {
    const args: string[] = [];
    // Only pass --root when we have one: yserve defaults to its own working
    // directory, and an empty --root would be a path that resolves to nothing.
    if (root && root.length > 0) {
        args.push('--root', root);
    }
    if (warnings === true) {
        args.push('-W');
    }
    return args;
}

export function config(): {
    serverPath: string | undefined;
    rootPath: string | undefined;
    checkOnChange: boolean;
    warnings: boolean;
    trace: 'off' | 'messages' | 'verbose';
} {
    const cfg = vscode.workspace.getConfiguration('y.lsp');
    return {
        serverPath: cfg.get<string>('serverPath') || undefined,
        rootPath: cfg.get<string>('rootPath') || undefined,
        // R1.6. `false` is `yserve`'s own default, so this is today's behaviour
        // spelled out rather than a new default -- see serverArgs for why.
        warnings: cfg.get<boolean>('warnings', false),
        // Default ON, and the default is spelled out rather than left to
        // `get<boolean>`'s own: a client that sends nothing must get the
        // behaviour the server has always had. The server reads it as
        // `initializationOptions.checkOnChange` and treats anything that is not a
        // bool as ON, so the two defaults cannot drift apart silently.
        checkOnChange: cfg.get<boolean>('checkOnChange', true),
        trace: cfg.get<'off' | 'messages' | 'verbose'>('trace.server', 'off'),
    };
}

/** The workspace root: the setting if given, else the first folder. */
export function workspaceRoot(): string | undefined {
    const cfg = config();
    if (cfg.rootPath && cfg.rootPath.length > 0) {
        return path.resolve(cfg.rootPath);
    }
    const folders = vscode.workspace.workspaceFolders;
    if (folders && folders.length > 0) {
        return folders[0].uri.fsPath;
    }
    return undefined;
}
