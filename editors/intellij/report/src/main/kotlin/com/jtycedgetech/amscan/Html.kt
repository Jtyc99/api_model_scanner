package com.jtycedgetech.amscan

/**
 * Colours taken from the running IDE, so the table wears whatever theme the
 * editor is wearing. The VS Code editor gets the same effect from
 * `var(--vscode-*)`; here they have to be read and injected.
 */
data class Theme(
  val foreground: String,
  val background: String,
  val border: String,
  val inputBackground: String,
  val hover: String,
  val link: String,
  val error: String,
  val fontFamily: String,
  val monoFamily: String,
  val fontSize: String,
)

/**
 * The report as a real table with checkbox cells — the thing Markdown cannot
 * give you, since GFM only makes checkboxes interactive inside list items.
 *
 * A class cell spans its fields' rows and a field cell spans its parts', so
 * the nesting is visible in the layout rather than in indentation. This is a
 * deliberate port of `editors/vscode/src/webview.ts`: same columns, same
 * spans, same filter, so the two editors look and behave alike.
 */
fun renderHtml(
  theme: Theme,
  /** The report, already serialised, baked into the page. */
  initialJson: String = "{\"classes\":[]}",
  /** JavaScript that sends one message to the IDE, using `message`. */
  bridge: String = "",
): String = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>API Model Scanner report</title>
<style>
  body {
    margin: 0; padding: 0 0 2rem;
    font-family: ${theme.fontFamily};
    font-size: ${theme.fontSize};
    color: ${theme.foreground};
    background: ${theme.background};
  }
  header {
    position: sticky; top: 0; z-index: 3;
    padding: 10px 16px;
    background: ${theme.background};
    border-bottom: 1px solid ${theme.border};
    display: flex; flex-wrap: wrap; gap: 10px; align-items: center;
  }
  h1 { font-size: 1.05em; margin: 0; font-weight: 600; }
  .summary { opacity: .75; margin-right: auto; }
  .select-all { display: flex; align-items: center; gap: 6px; cursor: pointer; }
  input[type="search"] {
    font: inherit; color: ${theme.foreground};
    background: ${theme.inputBackground};
    border: 1px solid ${theme.border};
    border-radius: 4px; padding: 3px 9px; min-width: 14ch;
  }
  button {
    font: inherit; color: ${theme.foreground};
    background: transparent;
    border: 1px solid ${theme.border};
    border-radius: 4px; padding: 3px 9px; cursor: pointer;
  }
  button:hover { background: ${theme.hover}; }
  .wrap { padding: 14px 16px 0; }
  table { border-collapse: collapse; width: 100%; }
  th, td {
    text-align: left; padding: 7px 12px; vertical-align: top;
    border: 1px solid ${theme.border};
  }
  thead th {
    position: sticky; top: 47px; z-index: 2;
    background: ${theme.background};
    font-weight: 600;
  }
  label.box { display: flex; align-items: flex-start; gap: 8px; cursor: pointer; }
  label.box input { margin: 2px 0 0; cursor: pointer; flex: none; }
  .class-name { font-weight: 600; }
  .mono { font-family: ${theme.monoFamily}; }
  .path {
    display: block; opacity: .65; font-size: .92em; margin-top: 3px;
    font-family: ${theme.monoFamily};
    cursor: pointer; text-decoration: underline; text-underline-offset: 2px;
  }
  .dead { color: ${theme.error}; font-size: .92em; }
  .line {
    font-family: ${theme.monoFamily}; color: ${theme.link};
    cursor: pointer; white-space: nowrap;
  }
  .line:hover { text-decoration: underline; }
  tr:hover td { background: ${theme.hover}; }
  .note { padding: 2rem 16px; opacity: .75; }
  .warn { color: ${theme.error}; }
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
<script>
(function () {
  const root = document.getElementById('root');
  const selectAllBox = document.getElementById('selectAll');
  const filterBox = document.getElementById('filter');
  let report = { classes: [] };

  // The bridge into the IDE, written into the page rather than injected
  // after load: a first paint that depends on a later injection is a first
  // paint that can silently not happen. In VS Code this same call is
  // `acquireVsCodeApi().postMessage`.
  const send = function (payload) {
    const message = JSON.stringify(payload);
    ${bridge}
  };

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
      send({ type: 'set', line: line, checked: input.checked }));
    label.appendChild(input);
    if (text !== undefined) label.appendChild(el('span', textClass, text));
    return label;
  }

  function matching() {
    const needle = filterBox.value.trim().toLowerCase();
    if (!needle) return report.classes;
    return report.classes
      .map(function (block) {
        if (block.name.toLowerCase().includes(needle)) return block;
        const fields = block.fields.filter(function (f) {
          return f.name.toLowerCase().includes(needle);
        });
        return fields.length ? Object.assign({}, block, { fields: fields }) : null;
      })
      .filter(Boolean);
  }

  function firstFileIn(block) {
    for (const field of block.fields) {
      for (const part of field.parts) {
        if (part.file) return part.file;
      }
    }
    return undefined;
  }

  function classCell(block, height) {
    const cell = el('td', 'class');
    cell.rowSpan = height;

    if (block.column >= 0) {
      cell.appendChild(box(block.line, block.checked, block.name, 'class-name'));
    } else {
      cell.appendChild(el('span', 'class-name', block.name));
    }
    if (block.dead) cell.appendChild(el('div', 'dead', '\u{1F480} dead — taken whole'));

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
    ['Model Class', 'Field Name', 'Field Parts', 'Line'].forEach(function (title) {
      head.appendChild(el('th', null, title));
    });
    const thead = document.createElement('thead');
    thead.appendChild(head);
    table.appendChild(thead);

    const body = document.createElement('tbody');

    for (const block of blocks) {
      // A field with no parts still occupies one row.
      const height = block.fields.reduce(function (total, field) {
        return total + Math.max(1, field.parts.length);
      }, 0) || 1;
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
            partCell.appendChild(el('span', 'warn', 'No removable declaration found'));
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

  selectAllBox.addEventListener('change', function () {
    if (report.selectAll) {
      send({ type: 'set', line: report.selectAll.line, checked: selectAllBox.checked });
    }
  });
  filterBox.addEventListener('input', render);
  document.getElementById('text').addEventListener('click', () =>
    send({ type: 'openAsText' }));

  // Called from Kotlin whenever the document changes.
  window.__amscanUpdate = function (json) {
    report = JSON.parse(json);
    render();
  };

  // The report is in the page already, so the table is drawn before any
  // call from the IDE arrives — and still drawn if none ever does.
  report = ${initialJson};
  render();
}());
</script>
</body>
</html>
"""
