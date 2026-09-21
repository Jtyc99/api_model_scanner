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
 * A class cell spans its fields' rows and a field cell spans its parts', so
 * the nesting is visible in the layout rather than in indentation. Filtering
 * rebuilds the table from a narrowed model rather than hiding rows, because
 * a hidden row inside a `rowspan` leaves the span pointing at nothing.
 *
 * Colours come from VS Code's own theme variables, so the table matches
 * whatever the editor is wearing.
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
    margin: 0; padding: 0 0 2rem;
    font-family: var(--vscode-font-family);
    font-size: var(--vscode-font-size);
    color: var(--vscode-foreground);
    background: var(--vscode-editor-background);
  }
  header {
    position: sticky; top: 0; z-index: 3;
    padding: 10px 16px;
    background: var(--vscode-editor-background);
    border-bottom: 1px solid var(--vscode-panel-border);
    display: flex; flex-wrap: wrap; gap: 10px; align-items: center;
  }
  h1 { font-size: 1.05em; margin: 0; font-weight: 600; }
  .summary { opacity: .75; margin-right: auto; }
  .select-all { display: flex; align-items: center; gap: 6px; cursor: pointer; }
  input[type="search"] {
    font: inherit; color: var(--vscode-foreground);
    background: var(--vscode-input-background);
    border: 1px solid var(--vscode-panel-border);
    border-radius: 4px; padding: 3px 9px; min-width: 14ch;
  }
  button {
    font: inherit; color: var(--vscode-foreground);
    background: var(--vscode-button-secondaryBackground, transparent);
    border: 1px solid var(--vscode-panel-border);
    border-radius: 4px; padding: 3px 9px; cursor: pointer;
  }
  button:hover { background: var(--vscode-toolbar-hoverBackground); }
  .wrap { padding: 14px 16px 0; }
  table { border-collapse: collapse; width: 100%; }
  th, td {
    text-align: left; padding: 7px 12px; vertical-align: top;
    border: 1px solid var(--vscode-panel-border);
  }
  thead th {
    position: sticky; top: 47px; z-index: 2;
    background: var(--vscode-editor-background);
    font-weight: 600;
  }
  td.class, td.field { vertical-align: top; }
  label.box {
    display: flex; align-items: flex-start; gap: 8px; cursor: pointer;
  }
  label.box input { margin: 2px 0 0; cursor: pointer; flex: none; }
  .class-name { font-weight: 600; }
  .mono { font-family: var(--vscode-editor-font-family); }
  .path {
    display: block; opacity: .65; font-size: .92em; margin-top: 3px;
    font-family: var(--vscode-editor-font-family);
    cursor: pointer; text-decoration: underline; text-underline-offset: 2px;
  }
  .dead { color: var(--vscode-errorForeground); font-size: .92em; }
  .line {
    font-family: var(--vscode-editor-font-family);
    color: var(--vscode-textLink-foreground);
    cursor: pointer; white-space: nowrap;
  }
  .line:hover { text-decoration: underline; }
  tr:hover td { background: var(--vscode-list-hoverBackground); }
  .note { padding: 2rem 16px; opacity: .75; }
  .warn { color: var(--vscode-errorForeground); }
</style>
</head>
<body>
<header>
  <h1 id="title">Report</h1>
  <label class="select-all">
    <input type="checkbox" id="selectAll"> Select All
  </label>
  <span class="summary" id="summary"></span>
  <input type="search" id="filter" placeholder="Filter fields…" aria-label="Filter fields">
  <button id="text">Open as text</button>
</header>
<div class="wrap"><div id="root"></div></div>
<script nonce="${id}">
(function () {
  const api = acquireVsCodeApi();
  const root = document.getElementById('root');
  const selectAllBox = document.getElementById('selectAll');
  const filterBox = document.getElementById('filter');
  let report = { classes: [] };

  const send = (message) => api.postMessage(message);

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  /** A checkbox that reports the state it was moved *to*. */
  function box(line, checked, text, textClass) {
    const label = el('label', 'box');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = checked;
    input.addEventListener('change', () =>
      send({ type: 'set', line, checked: input.checked }));
    label.appendChild(input);
    if (text !== undefined) label.appendChild(el('span', textClass, text));
    return label;
  }

  function matching() {
    const needle = filterBox.value.trim().toLowerCase();
    if (!needle) return report.classes;
    return report.classes
      .map((block) => {
        if (block.name.toLowerCase().includes(needle)) return block;
        const fields = block.fields.filter((f) =>
          f.name.toLowerCase().includes(needle));
        return fields.length ? Object.assign({}, block, { fields }) : null;
      })
      .filter(Boolean);
  }

  function render() {
    const scroll = window.scrollY;
    root.textContent = '';

    document.getElementById('title').textContent = report.title || 'Report';
    document.getElementById('summary').textContent = report.summary || '';
    selectAllBox.checked = report.selectAll ? report.selectAll.checked : false;
    selectAllBox.disabled = !report.selectAll;

    const blocks = matching();
    if (!blocks.length) {
      root.appendChild(el('div', 'note',
        report.classes.length ? 'Nothing matches that filter.'
                              : 'Nothing to select — no fields in this report.'));
      return;
    }

    const table = document.createElement('table');
    const head = document.createElement('tr');
    for (const title of ['Model Class', 'Field Name', 'Field Parts', 'Line']) {
      head.appendChild(el('th', null, title));
    }
    const thead = document.createElement('thead');
    thead.appendChild(head);
    table.appendChild(thead);

    const body = document.createElement('tbody');

    for (const block of blocks) {
      // A field with no parts still occupies one row.
      const height = block.fields.reduce(
        (total, field) => total + Math.max(1, field.parts.length), 0) || 1;
      let firstOfClass = true;

      if (!block.fields.length) {
        const row = document.createElement('tr');
        row.appendChild(classCell(block, 1));
        row.appendChild(el('td'));
        row.appendChild(el('td'));
        row.appendChild(el('td'));
        body.appendChild(row);
        continue;
      }

      for (const field of block.fields) {
        const span = Math.max(1, field.parts.length);
        let firstOfField = true;

        const rows = field.parts.length ? field.parts : [null];
        for (const part of rows) {
          const row = document.createElement('tr');

          if (firstOfClass) {
            row.appendChild(classCell(block, height));
            firstOfClass = false;
          }
          if (firstOfField) {
            const cell = el('td', 'field');
            cell.rowSpan = span;
            cell.appendChild(box(field.line, field.checked, field.name, 'mono'));
            row.appendChild(cell);
            firstOfField = false;
          }

          const partCell = el('td');
          const lineCell = el('td');

          if (part) {
            partCell.appendChild(box(part.line, part.checked, part.label, 'mono'));
            if (part.file && part.sourceLine) {
              const link = el('span', 'line', 'line ' + part.sourceLine);
              link.addEventListener('click', () =>
                send({ type: 'open', file: part.file, line: part.sourceLine }));
              lineCell.appendChild(link);
            }
          } else {
            partCell.appendChild(el('span', 'warn',
              'No removable declaration found'));
          }

          row.appendChild(partCell);
          row.appendChild(lineCell);
          body.appendChild(row);
        }
      }
    }

    table.appendChild(body);
    root.appendChild(table);
    window.scrollTo(0, scroll);
  }

  function classCell(block, height) {
    const cell = el('td', 'class');
    cell.rowSpan = height;

    if (block.column >= 0) {
      cell.appendChild(box(block.line, block.checked, block.name, 'class-name'));
    } else {
      cell.appendChild(el('span', 'class-name', block.name));
    }
    if (block.dead) cell.appendChild(el('div', 'dead', '💀 dead — taken whole'));

    if (block.file) {
      const path = el('span', 'path', block.file);
      const target = firstFileIn(block);
      if (target) {
        path.addEventListener('click', () => send({ type: 'open', file: target }));
      }
      cell.appendChild(path);
    }
    return cell;
  }

  function firstFileIn(block) {
    for (const field of block.fields) {
      for (const part of field.parts) {
        if (part.file) return part.file;
      }
    }
    return undefined;
  }

  selectAllBox.addEventListener('change', () => {
    if (report.selectAll) {
      send({ type: 'set', line: report.selectAll.line, checked: selectAllBox.checked });
    }
  });
  filterBox.addEventListener('input', render);
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
