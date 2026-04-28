const vscode = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

let client;

function activate(context) {
    const config = vscode.workspace.getConfiguration("zigpp");
    // serverPath defaults to a bare "zpp" so VS Code's child_process spawn
    // resolves it from the user's PATH; absolute paths also work as-is.
    const serverPath = config.get("serverPath", "zpp");
    const serverArgs = config.get("serverArgs", ["lsp"]);

    const serverOptions = {
        command: serverPath,
        args: serverArgs,
        transport: TransportKind.stdio,
    };

    const clientOptions = {
        documentSelector: [{ scheme: "file", language: "zigpp" }],
        // The zpp server only implements textDocument/diagnostic (pull model).
        // Without these options, vscode-languageclient falls back to push-mode
        // (publishDiagnostics) and our server, which never sends those, looks silent.
        diagnosticPullOptions: { onChange: true, onSave: true },
        diagnosticCollectionName: "zigpp",
    };

    client = new LanguageClient("zigpp", "Zig++", serverOptions, clientOptions);
    client.start();
}

function deactivate() {
    if (client) return client.stop();
    return undefined;
}

module.exports = { activate, deactivate };
