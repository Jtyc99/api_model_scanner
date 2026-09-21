import * as vscode from 'vscode';

/** A fresh nonce per load, so the CSP can allow exactly one script. */
function nonce(): string {
  const alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let value = '';
  for (let i = 0; i < 32; i++) {
    value += alphabet[Math.floor(Math.random() * alphabet.length)];
  }
  return value;
}

/**
 * The report as a real table with checkbox cells — the thing Markdown cannot
 * give you, since GFM only makes checkboxes interactive inside list items.
 *
 * Colours come from VS Code's own theme variables rather than a palette of
 * our own, so the table matches whatever the editor is wearing.
 */
export function renderHtml(webview: vscode.Webview): string {
  const id = nonce();

  return /* html */ `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy"
  content="default-src 'none'; style-src ${webview.cspSource} 'unsafe-inline'; script-src 'nonce-${id}';">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>API Model Scanner report</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0;
    padding: 0 0 2rem;
    font-family: var(--vscode-font-family);
    font-size: var(--vscode-font-size);
    color: var(--vscode-foreground);
    background: var(--vscode-editor-background);
  }
  header {
    position: sticky; top: 0; z-index: 2;
    padding: 10px 16px;
    background: var(--vscode-editor-background);
    border-bottom: 1px solid var(--vscode-panel-border);
    display: flex; flex-wrap: wrap; gap: 8px; align-items: center;
  }
  h1 { font-size: 1.05em; margin: 0 8px 0 0; font-weight: 600; }
  .summary { opacity: .75; margin-right: auto; }
  button, input[type="search"] {
    font: inherit; color: var(--vscode-foreground);
    background: var(--vscode-button-secondaryBackground, transparent);
    border: 1px solid var(--vscode-panel-border);
    border-radius: 4px; padding: 3px 9px;
  }
  button:hover { background: var(--vscode-toolbar-hoverBackground); cursor: pointer; }
  input[type="search"] { background: var(--vscode-input-background); min-width: 12ch; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 3px 10px; vertical-align: baseline; }
  thead th {
    position: sticky; top: 46px; z-index: 1;
    background: var(--vscode-editor-background);
    border-bottom: 1px solid var(--vscode-panel-border);
    font-weight: 600; opacity: .75;
  }
  tr.class > td {
    padding-top: 16px; border-bottom: 1px solid var(--vscode-panel-border);
  }
  .class-name { font-weight: 600; font-size: 1.05em; }
  .path {
    opacity: .7; font-family: var(--vscode-editor-font-family);
    margin-left: .6em; cursor: pointer; text-decoration: underline;
    text-underline-offset: 2px;
  }
  .dead { color: var(--vscode-errorForeground); margin-left: .6em; }
  tr.field:hover, tr.part:hover { background: var(--vscode-list-hoverBackground); }
  .field-name {
    font-family: var(--vscode-editor-font-family); font-weight: 600;
  }
  .part-label {
    font-family: var(--vscode-editor-font-family);
    opacity: .85; padding-left: 2.2em;
  }
  .count { opacity: .6; margin-left: .6em; font-weight: 400; }
  .line {
    font-family: var(--vscode-editor-font-family);
    color: var(--vscode-textLink-foreground);
    cursor: pointer; white-space: nowrap;
  }
  .line:hover { text-decoration: underline; }
  td.box { width: 1.6em; }
  input[type="checkbox"] { cursor: pointer; margin: 0; }
  .empty { padding: 2rem 1rem; opacity: .75; }
  tr.hidden { display: none; }
</style>
</head>
<body>
<header>
  <h1 id="title">Report</h1>
  <span class="summary" id="summary"></span>
  <input type="search" id="filter" placeholder="Filter fields…" aria-label="Filter fields">
  <button id="all">Tick all</button>
  <button id="none">Clear</button>
  <button id="text">Open as text</button>
</header>
<div id="root"></div>
<script nonce="${id}">
(function () {
  const vscodeApi = acquireVsCodeApi();
  const root = document.getElementById('root');
  let report = { classes: [] };

  function send(message) { vscodeApi.postMessage(message); }

  function boxLines(predicate) {
    const lines = [];
    if (report.selectAll) lines.push(report.selectAll.line);
    for (const block of report.classes) {
      if (block.column >= 0) lines.push(block.line);
      for (const field of block.fields) {
        lines.push(field.line);
        for (const part of field.parts) lines.push(part.line);
      }
    }
    return predicate ? lines.filter(predicate) : lines;
  }

  function cell(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function checkbox(line, checked, label) {
    const td = cell('td', 'box');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = checked;
    input.setAttribute('aria-label', label);
    input.addEventListener('change', () => send({ type: 'toggle', line }));
    td.appendChild(input);
    return td;
  }

  function render() {
    const scroll = window.scrollY;
    root.textContent = '';

    document.getElementById('title').textContent = report.title || 'Report';
    document.getElementById('summary').textContent = report.summary || '';

    if (!report.classes.length) {
      root.appendChild(cell('div', 'empty', 'Nothing to select — no fields in this report.'));
      return;
    }

    const table = document.createElement('table');
    const thead = document.createElement('thead');
    const headRow = document.createElement('tr');
    headRow.appendChild(cell('th', 'box', ''));
    headRow.appendChild(cell('th', null, 'Field / part'));
    headRow.appendChild(cell('th', null, 'Source'));
    thead.appendChild(headRow);
    table.appendChild(thead);

    const body = document.createElement('tbody');

    for (const block of report.classes) {
      const classRow = document.createElement('tr');
      classRow.className = 'class';

      if (block.column >= 0) {
        classRow.appendChild(checkbox(block.line, block.checked, 'All of ' + block.name));
      } else {
        classRow.appendChild(cell('td', 'box', ''));
      }

      const nameCell = cell('td');
      nameCell.appendChild(cell('span', 'class-name', block.name));
      if (block.dead) nameCell.appendChild(cell('span', 'dead', '💀 dead'));
      classRow.appendChild(nameCell);

      const pathCell = cell('td');
      if (block.file) {
        const anchor = cell('span', 'path', block.file);
        const target = firstFileIn(block);
        if (target) {
          anchor.addEventListener('click', () => send({ type: 'open', file: target }));
        }
        pathCell.appendChild(anchor);
      }
      classRow.appendChild(pathCell);
      body.appendChild(classRow);

      for (const field of block.fields) {
        const row = document.createElement('tr');
        row.className = 'field';
        row.dataset.name = (block.name + '.' + field.name).toLowerCase();
        row.appendChild(checkbox(field.line, field.checked, field.name));

        const label = cell('td');
        label.appendChild(cell('span', 'field-name', field.name));
        label.appendChild(cell('span', 'count',
          field.parts.length + (field.parts.length === 1 ? ' part' : ' parts')));
        row.appendChild(label);
        row.appendChild(cell('td'));
        body.appendChild(row);

        for (const part of field.parts) {
          const partRow = document.createElement('tr');
          partRow.className = 'part';
          partRow.dataset.name = (block.name + '.' + field.name).toLowerCase();
          partRow.appendChild(checkbox(part.line, part.checked, part.label));
          partRow.appendChild(cell('td', 'part-label', part.label));

          const source = cell('td');
          if (part.file && part.sourceLine) {
            const link = cell('span', 'line', 'line ' + part.sourceLine);
            link.addEventListener('click', () =>
              send({ type: 'open', file: part.file, line: part.sourceLine }));
            source.appendChild(link);
          }
          partRow.appendChild(source);
          body.appendChild(partRow);
        }
      }
    }

    table.appendChild(body);
    root.appendChild(table);
    applyFilter();
    window.scrollTo(0, scroll);
  }

  function firstFileIn(block) {
    for (const field of block.fields) {
      for (const part of field.parts) {
        if (part.file) return part.file;
      }
    }
    return undefined;
  }

  function applyFilter() {
    const needle = document.getElementById('filter').value.trim().toLowerCase();
    for (const row of root.querySelectorAll('tr.field, tr.part')) {
      const match = !needle || (row.dataset.name || '').includes(needle);
      row.classList.toggle('hidden', !match);
    }
  }

  document.getElementById('filter').addEventListener('input', applyFilter);
  document.getElementById('all').addEventListener('click', () =>
    send({ type: 'setAll', lines: boxLines(), checked: true }));
  document.getElementById('none').addEventListener('click', () =>
    send({ type: 'setAll', lines: boxLines(), checked: false }));
  document.getElementById('text').addEventListener('click', () =>
    send({ type: 'openAsText' }));

  window.addEventListener('message', (event) => {
    if (event.data && event.data.type === 'update') {
      report = event.data.report;
      render();
    }
  });
}());
</script>
</body>
</html>`;
}
