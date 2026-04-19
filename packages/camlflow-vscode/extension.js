"use strict";

const vscode = require("vscode");
const {
  LanguageClient,
  RevealOutputChannelOn,
  TransportKind,
} = require("vscode-languageclient/node");

let client;

function serverCommand() {
  const config = vscode.workspace.getConfiguration("camlflow");
  const command = config.get("lsp.command", "camlflow");
  const args = config.get("lsp.args", ["lsp"]);
  return { command, args };
}

async function startClient(context) {
  const { command, args } = serverCommand();
  const outputChannel = vscode.window.createOutputChannel("CamlFlow LSP");
  context.subscriptions.push(outputChannel);

  const serverOptions = {
    command,
    args,
    transport: TransportKind.stdio,
  };

  const clientOptions = {
    documentSelector: [{ language: "camlflow", scheme: "file" }],
    outputChannel,
    revealOutputChannelOn: RevealOutputChannelOn.Never,
    synchronize: {
      configurationSection: "camlflow",
    },
  };

  client = new LanguageClient(
    "camlflow-lsp",
    "CamlFlow Language Server",
    serverOptions,
    clientOptions,
  );

  try {
    await client.start();
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error);
    void vscode.window.showErrorMessage(
      `Failed to start CamlFlow language server: ${message}`,
    );
  }
}

async function restartClient(context) {
  if (client) {
    const existing = client;
    client = undefined;
    await existing.stop();
  }
  await startClient(context);
}

async function activate(context) {
  await startClient(context);

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration(async (event) => {
      if (event.affectsConfiguration("camlflow.lsp")) {
        await restartClient(context);
      }
    }),
  );
}

async function deactivate() {
  if (!client) {
    return;
  }
  const existing = client;
  client = undefined;
  await existing.stop();
}

module.exports = {
  activate,
  deactivate,
};
