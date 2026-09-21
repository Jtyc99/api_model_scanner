import * as vscode from 'vscode';

import { desiredStates, parseReport, setBox, type Report } from './report';
import { renderHtml } from './webview';

export function activate(context: vscode.ExtensionContext): void {
  context.subscriptions.push(ReportEditorProvider.register(context));
}

export function deactivate(): void {
  // Nothing to tear down: every disposable is registered on the context.
}

/** Messages the webview sends back. */
type Incoming =
  | { type: 'set'; line: number; checked: boolean }
  | { type: 'open'; file: string; line?: number }
  | { type: 'openAsText' };

/**
 * Renders a report as a real table with checkbox cells.
 *
 * The document stays the source of truth. Every toggle is a one-character
 * `WorkspaceEdit` on the underlying Markdown, so the file the Dart CLI reads
 * is always the file you are looking at — there is no separate state to get
 * out of step, and uninstalling the extension leaves a report that still
 * works by hand.
 */
class ReportEditorProvider implements vscode.CustomTextEditorProvider {
  private static readonly viewType = 'amscan.report';

  static register(_context: vscode.ExtensionContext): vscode.Disposable {
    return vscode.window.registerCustomEditorProvider(
      ReportEditorProvider.viewType,
      new ReportEditorProvider(),
      {
        webviewOptions: { retainContextWhenHidden: true },
        supportsMultipleEditorsPerDocument: false,
      },
    );
  }

  async resolveCustomTextEditor(
    document: vscode.TextDocument,
    panel: vscode.WebviewPanel,
    _token: vscode.CancellationToken,
  ): Promise<void> {
    panel.webview.options = { enableScripts: true };
    panel.webview.html = renderHtml(panel.webview);

    const post = () => {
      const report: Report = parseReport(document.getText());
      void panel.webview.postMessage({ type: 'update', report });
    };

    // Re-post on every change, including our own edits: the webview keeps its
    // scroll position, so the cost is invisible and external edits (someone
    // typing an `x`, or a fresh `amscan scan`) stay in sync.
    const changes = vscode.workspace.onDidChangeTextDocument((event) => {
      if (event.document.uri.toString() === document.uri.toString()) {
        post();
      }
    });
    panel.onDidDispose(() => changes.dispose());

    panel.webview.onDidReceiveMessage(async (message: Incoming) => {
      switch (message.type) {
        case 'set':
          await this.applyCascade(document, message.line, message.checked);
          return;
        case 'open':
          await openSource(message.file, message.line);
          return;
        case 'openAsText':
          await vscode.commands.executeCommand(
            'vscode.openWith',
            document.uri,
            'default',
          );
          return;
      }
    });

    post();
  }

  /**
   * Sets the box on [line], and every box the cascade moves with it.
   *
   * Applied as one `WorkspaceEdit` so ticking a class is a single undo step,
   * and computed against one snapshot so line numbers cannot shift underneath
   * it — each edit replaces exactly one character, which keeps every offset
   * stable no matter how many boxes move.
   */
  private async applyCascade(
    document: vscode.TextDocument,
    line: number,
    checked: boolean,
  ): Promise<void> {
    const text = document.getText();
    const wanted = desiredStates(parseReport(text), line, checked);

    const edit = new vscode.WorkspaceEdit();
    let touched = 0;

    for (const [at, state] of wanted) {
      const box = setBox(text, at, state);
      if (!box) {
        continue; // Already in the wanted state; nothing to write.
      }
      edit.replace(
        document.uri,
        new vscode.Range(box.line, box.column, box.line, box.column + 1),
        box.replacement,
      );
      touched++;
    }

    if (touched === 0) {
      return;
    }

    const applied = await vscode.workspace.applyEdit(edit);
    if (!applied) {
      void vscode.window.showErrorMessage(
        'Could not update the report — is the file writable?',
      );
    }
  }
}

/** Opens a Dart file beside the report, on [line] when one is known. */
async function openSource(file: string, line?: number): Promise<void> {
  const uri = vscode.Uri.file(file);

  try {
    const document = await vscode.workspace.openTextDocument(uri);
    const target = Math.max(0, (line ?? 1) - 1);
    const position = new vscode.Position(target, 0);

    await vscode.window.showTextDocument(document, {
      viewColumn: vscode.ViewColumn.Beside,
      preview: true,
      selection: new vscode.Range(position, position),
    });
  } catch {
    void vscode.window.showErrorMessage(`Could not open ${file}`);
  }
}
