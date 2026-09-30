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
  table { border-collapse: collapse; table-layout: fixed; width: 100%; }
  th, td {
    text-align: left; padding: 7px 12px; vertical-align: top;
    border: 1px solid ${theme.border};
    overflow: hidden;
  }
  /* Full text when the column has room for it; an ellipsis when it does not,
     and the whole of it on hover either way. */
  .clip {
    display: block; min-width: 0;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  label.box .clip { flex: 1 1 auto; }
  /* Laid out once without clipping, to learn how wide each column wants to be. */
  table.measuring { table-layout: auto; width: max-content !important; }
  table.measuring col { width: auto !important; }
  table.measuring .clip { overflow: visible; text-overflow: clip; }
  /* `e-resize`, not the `col-resize` VS Code uses. The IDE's embedded browser
     hands the page's cursor to Swing as one of AWT's built-in cursors, and
     only the single-edge resize shapes survive that translation: `col-resize`
     arrives as the plain arrow, so nobody can tell the edge is draggable.
     On macOS, AWT draws this one as the left-right resize cursor. */
  .grip {
    position: absolute; top: 0; right: -1px; width: 7px; height: 100%;
    cursor: e-resize; user-select: none; z-index: 1;
  }
  .grip:hover, .grip.active { background: ${theme.link}; opacity: .6; }
  body.resizing, body.resizing * { cursor: e-resize !important; user-select: none !important; }
  .section { margin-bottom: 22px; }
  .section-head {
    display: grid; grid-template-columns: 1fr; column-gap: 10px; row-gap: 3px;
    align-items: baseline; width: 100%;
    margin: 0 0 8px; padding: 2px 0; text-align: left;
    font: inherit; font-weight: 600; color: inherit;
    background: transparent; border: 0; border-radius: 0; cursor: default;
  }
  /* A bar that reads as something to click: bordered, filled, with a hover
     state and a Show / Hide label, rather than a heading with a caret. */
  button.section-head {
    grid-template-columns: 1em 1fr auto;
    padding: 8px 12px; cursor: pointer;
    border: 1px solid ${theme.border}; border-radius: 6px; background: ${theme.inputBackground};
  }
  button.section-head:hover { background: ${theme.hover}; }
  .section.guarded button.section-head { border-color: ${theme.error}; }
  .section.guarded .section-title { color: ${theme.error}; }
  .caret { flex: none; }
  .count { font-weight: 400; opacity: .7; margin-left: 8px; }
  .toggle { font-weight: 400; text-decoration: underline; text-underline-offset: 2px; }
  .hint { grid-column: 2 / 4; font-weight: 400; opacity: .8; font-size: .92em; }
  .section-note { margin: 0 0 10px; opacity: .75; max-width: 75ch; }
  .read { margin-bottom: 2px; }
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
    opacity: .65; font-size: .92em; margin-top: 3px;
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
  <button id="fit" title="Undo any column resizing">Fit columns</button>
  <button id="text">Open as text</button>
</header>
<div class="wrap"><div id="root"></div></div>
<script>
(function () {
  const root = document.getElementById('root');
  const selectAllBox = document.getElementById('selectAll');
  const filterBox = document.getElementById('filter');
  let report = { classes: [], guarded: [] };

  // Remembered where the embedded browser allows it. When it does not —
  // storage can be off for a page with no origin — column widths and folded
  // tables simply last as long as this editor tab.
  function loadSaved(key) {
    try {
      return JSON.parse(window.localStorage.getItem('amscan.' + key));
    } catch (e) {
      return null;
    }
  }
  function saveSaved(key, value) {
    try {
      window.localStorage.setItem('amscan.' + key, JSON.stringify(value));
    } catch (e) {
      // Not worth interrupting anyone over.
    }
  }

  // The bridge into the IDE, written into the page rather than injected
  // after load: a first paint that depends on a later injection is a first
  // paint that can silently not happen. In VS Code this same call is
  // `acquireVsCodeApi().postMessage`.
  const send = function (payload) {
    const message = JSON.stringify(payload);
    ${bridge}
  };

  // <shared-table>
  // Everything from here to the closing marker is identical in the VS Code
  // and IntelliJ editors, and a test in the Dart package fails if the two
  // copies ever differ. The host supplies send(), loadSaved(), saveSaved(),
  // report, root, selectAllBox and filterBox. No dollar signs, backticks or
  // backslashes, so the same text sits unescaped in a Kotlin raw string and a
  // TypeScript template literal.

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  /** Text that ends in an ellipsis when its column is too narrow for it. */
  function clipped(tag, className, text) {
    const node = el(tag, (className ? className + ' ' : '') + 'clip', text);
    node.title = text;
    return node;
  }

  /** A checkbox that reports the state it was moved *to*. */
  function box(line, checked, text, textClass) {
    const label = el('label', 'box');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = checked;
    input.addEventListener('change', function () {
      send({ type: 'set', line: line, checked: input.checked });
    });
    label.appendChild(input);
    if (text !== undefined) label.appendChild(clipped('span', textClass, text));
    return label;
  }

  function matching(blocks) {
    const needle = filterBox.value.trim().toLowerCase();
    if (!needle) return blocks;
    return blocks
      .map(function (block) {
        if (block.name.toLowerCase().includes(needle)) return block;
        const fields = block.fields.filter(function (f) {
          return f.name.toLowerCase().includes(needle);
        });
        return fields.length ? Object.assign({}, block, { fields: fields }) : null;
      })
      .filter(Boolean);
  }

  const COLUMNS = {
    main: ['Model Class', 'Field Name', 'Field Parts', 'Line'],
    guarded: ['Model Class', 'Field Name', 'Read At', 'Field Parts', 'Line'],
  };
  // The column that takes the spare width when everything fits.
  const GROW = { main: 2, guarded: 3 };
  const MIN_WIDTH = 48;

  // Widths only exist once someone drags. Until then every table is fitted
  // to its content, and refitted when the window changes size.
  let widths = loadSaved('widths') || {};

  // The fields read dynamically start folded away: they are never taken
  // without a tick of their own, so there is nothing to lose by not seeing
  // them at first — and their heading, with its count, stays on top where it
  // cannot be missed. The table that everything acts on starts open.
  const collapsed = Object.assign(
    { guarded: true, main: false }, loadSaved('collapsed') || {});

  function render() {
    const scroll = window.scrollY;
    root.textContent = '';

    const guardedAll = report.guarded || [];
    document.getElementById('title').textContent = report.title || 'Report';
    document.getElementById('summary').textContent = report.summary || '';
    selectAllBox.checked = report.selectAll ? report.selectAll.checked : false;
    selectAllBox.disabled = !report.selectAll;

    if (!report.classes.length && !guardedAll.length) {
      root.appendChild(el('div', 'note',
        'Nothing to select — no fields in this report.'));
      return;
    }

    const main = matching(report.classes);
    const guarded = matching(guardedAll);
    if (!main.length && !guarded.length) {
      root.appendChild(el('div', 'note', 'Nothing matches that filter.'));
      return;
    }

    // Folding only means something with two tables on the page. With one,
    // it would fold away everything there is; while filtering, it would hide
    // what the filter just found.
    const foldable = main.length > 0 && guarded.length > 0 &&
      !filterBox.value.trim();

    // The few rows that must not be missed go first, where nobody has to
    // scroll to find them.
    if (guarded.length) {
      // The report words its own headings — the unused and the disabled
      // report mean different things by them — and these are only what an
      // older report, which wrote none, falls back to.
      root.appendChild(section('guarded', guarded, {
        title: report.guardedTitle ||
          '⚠ Read dynamically — taken only when you tick them',
        note: report.guardedNote ||
          'Nothing references these by type, but a field of the same ' +
          'name is read through a dynamic receiver, which no reference ' +
          'search can follow. Removing one still compiles, then throws when ' +
          'that read runs. Select All and class boxes never tick these.',
        // Folded, this is all a newcomer sees of the section — so it says
        // what the rows are doing here, that nothing in them is lost, and
        // that the bar opens. A caret alone answers none of that.
        hint: 'Kept apart for you to check — nothing here is removed ' +
          'until you tick it. Click to show.',
        headed: true,
        foldable: foldable,
      }));
    }

    if (main.length) {
      root.appendChild(section('main', main, {
        title: report.mainTitle || 'Unused — safe to select together',
        hint: 'Click to show.',
        headed: guarded.length > 0,
        foldable: foldable,
      }));
    } else if (!report.classes.length) {
      root.appendChild(el('div', 'note',
        'Nothing here is safe to take without a tick of its own.'));
    }

    Array.prototype.forEach.call(root.querySelectorAll('table'), function (node) {
      if (shown(node)) size(node);
    });
    // A page drawn before it has its final size — an editor tab still being
    // laid out — is fitted again the moment it has one.
    requestAnimationFrame(refitUnsaved);
    window.scrollTo(0, scroll);
  }

  /** A table under a heading that folds it away, when folding is on offer. */
  function section(kind, blocks, options) {
    const node = el('section', 'section ' + kind);
    const open = !options.foldable || !collapsed[kind];
    const count = blocks.reduce(function (n, block) {
      return n + block.fields.length;
    }, 0);

    if (options.headed) {
      const head = el(options.foldable ? 'button' : 'div', 'section-head');
      if (options.foldable) {
        head.type = 'button';
        head.setAttribute('aria-expanded', String(open));
        head.title = open ? 'Hide this table' : 'Show this table';
        head.appendChild(el('span', 'caret', open ? '▾' : '▸'));
        head.addEventListener('click', function () {
          collapsed[kind] = open;
          saveSaved('collapsed', collapsed);
          render();
        });
      }
      const title = el('span', 'section-title', options.title);
      title.appendChild(el('span', 'count',
        count + ' field' + (count === 1 ? '' : 's')));
      head.appendChild(title);
      if (options.foldable) {
        // Words, not only a caret: someone who has never seen the page
        // should not have to guess that the bar opens.
        head.appendChild(el('span', 'toggle', open ? 'Hide' : 'Show'));
        if (!open && options.hint) head.appendChild(el('span', 'hint', options.hint));
      }
      node.appendChild(head);
    }

    const body = el('div', 'section-body');
    body.hidden = !open;
    if (options.note) body.appendChild(el('p', 'section-note', options.note));
    body.appendChild(table(kind, blocks));
    node.appendChild(body);
    return node;
  }

  /** Whether [node] is on screen — a folded table has no size to fit. */
  function shown(node) {
    return node.offsetParent !== null;
  }

  function table(kind, blocks) {
    const node = document.createElement('table');
    node.dataset.kind = kind;
    const columns = COLUMNS[kind];

    const group = document.createElement('colgroup');
    const head = document.createElement('tr');
    columns.forEach(function (title, index) {
      group.appendChild(document.createElement('col'));
      const cell = el('th');
      cell.appendChild(clipped('span', null, title));
      const grip = el('div', 'grip');
      grip.title = 'Drag to resize · double-click to fit';
      grip.addEventListener('mousedown', function (event) {
        drag(event, node, index);
      });
      grip.addEventListener('dblclick', function () { fitOne(node, index); });
      cell.appendChild(grip);
      head.appendChild(cell);
    });
    node.appendChild(group);
    const thead = document.createElement('thead');
    thead.appendChild(head);
    node.appendChild(thead);

    const body = document.createElement('tbody');
    for (const block of blocks) {
      // A field with nothing under it still occupies one row.
      const height = block.fields.reduce(function (total, field) {
        return total + rowsOf(field).length;
      }, 0) || 1;
      let firstOfClass = true;

      if (!block.fields.length) {
        const row = document.createElement('tr');
        row.appendChild(classCell(block, 1));
        for (let i = 1; i < columns.length; i++) row.appendChild(el('td'));
        body.appendChild(row);
        continue;
      }

      for (const field of block.fields) {
        const rows = rowsOf(field);
        const span = rows.length;
        let firstOfField = true;

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
            if (kind === 'guarded') row.appendChild(readsCell(field, span));
            firstOfField = false;
          }

          const partCell = el('td');
          const lineCell = el('td');
          if (part && part.snippet !== undefined) {
            partCell.appendChild(clipped('span', 'mono snippet', part.snippet));
          } else if (part) {
            partCell.appendChild(box(part.line, part.checked, part.label, 'mono'));
            if (part.file && part.sourceLine) {
              lineCell.appendChild(opener('line ' + part.sourceLine, part.file,
                part.sourceLine));
            }
          } else {
            partCell.appendChild(clipped('span', 'warn',
              'No removable declaration found'));
          }
          row.appendChild(partCell);
          row.appendChild(lineCell);
          body.appendChild(row);
        }
      }
    }
    node.appendChild(body);
    return node;
  }

  /**
   * What goes under a field, one row each: its parts when it has them, the
   * code it had commented out when it is disabled, or one empty row.
   */
  function rowsOf(field) {
    if (field.parts.length) return field.parts;
    if (field.snippets && field.snippets.length) {
      return field.snippets.map(function (text) { return { snippet: text }; });
    }
    return [null];
  }

  function opener(text, file, line) {
    const link = clipped('span', 'line', text);
    link.addEventListener('click', function () {
      send({ type: 'open', file: file, line: line });
    });
    return link;
  }

  function readsCell(field, span) {
    const cell = el('td', 'reads');
    cell.rowSpan = span;
    (field.reads || []).forEach(function (read) {
      if (read.file && read.sourceLine) {
        const link = opener(read.label, read.file, read.sourceLine);
        link.classList.add('read');
        cell.appendChild(link);
      } else {
        cell.appendChild(clipped('span', 'read', read.label));
      }
    });
    return cell;
  }

  function classCell(block, height) {
    const cell = el('td', 'class');
    cell.rowSpan = height;
    if (block.column >= 0) {
      cell.appendChild(box(block.line, block.checked, block.name, 'class-name'));
    } else {
      cell.appendChild(clipped('span', 'class-name', block.name));
    }
    if (block.dead) cell.appendChild(clipped('div', 'dead', '💀 dead — taken whole'));
    if (block.file) {
      const path = clipped('span', 'path', block.file);
      const target = firstFileIn(block);
      if (target) {
        path.addEventListener('click', function () {
          send({ type: 'open', file: target });
        });
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

  // ---- Column widths ------------------------------------------------------

  /** Each column's width when nothing is clipped. */
  function natural(node) {
    node.classList.add('measuring');
    const measured = Array.prototype.map.call(
      node.tHead.rows[0].cells,
      function (cell) { return Math.ceil(cell.getBoundingClientRect().width); });
    node.classList.remove('measuring');
    return measured;
  }

  /**
   * Content-sized when it all fits, with the spare room given to one column;
   * scaled down to the page when it does not, which is when ellipses appear.
   */
  function fitted(node) {
    const want = natural(node);
    const room = root.clientWidth;
    const total = want.reduce(function (a, b) { return a + b; }, 0);
    // Not laid out yet, or too narrow to share out: show everything and let
    // the page scroll sideways, rather than cut every column to a sliver.
    if (room < MIN_WIDTH * want.length) return want;
    if (total <= room) {
      want[GROW[node.dataset.kind]] += room - total;
      return want;
    }
    return want.map(function (w) {
      return Math.max(MIN_WIDTH, Math.floor(w * room / total));
    });
  }

  function current(node) {
    return Array.prototype.map.call(node.querySelectorAll('col'), function (col) {
      return parseFloat(col.style.width) || MIN_WIDTH;
    });
  }

  function apply(node, list) {
    const cols = node.querySelectorAll('col');
    let total = 0;
    list.forEach(function (w, i) {
      cols[i].style.width = w + 'px';
      total += w;
    });
    node.style.width = total + 'px';
  }

  function size(node) {
    const saved = widths[node.dataset.kind];
    apply(node, saved && saved.length === COLUMNS[node.dataset.kind].length
      ? saved
      : fitted(node));
  }

  function remember(node, list) {
    widths[node.dataset.kind] = list;
    saveSaved('widths', widths);
  }

  function drag(event, node, index) {
    event.preventDefault();
    const list = current(node);
    const startX = event.clientX;
    const startWidth = list[index];
    const grip = event.target;
    grip.classList.add('active');
    document.body.classList.add('resizing');

    function move(e) {
      list[index] = Math.max(MIN_WIDTH, Math.round(startWidth + e.clientX - startX));
      apply(node, list);
    }
    function up() {
      document.removeEventListener('mousemove', move);
      document.removeEventListener('mouseup', up);
      grip.classList.remove('active');
      document.body.classList.remove('resizing');
      remember(node, list);
    }
    document.addEventListener('mousemove', move);
    document.addEventListener('mouseup', up);
  }

  function fitOne(node, index) {
    const list = current(node);
    list[index] = Math.max(MIN_WIDTH, natural(node)[index]);
    apply(node, list);
    remember(node, list);
  }

  document.getElementById('fit').addEventListener('click', function () {
    widths = {};
    saveSaved('widths', widths);
    render();
  });

  function refitUnsaved() {
    Array.prototype.forEach.call(root.querySelectorAll('table'), function (node) {
      if (shown(node) && !widths[node.dataset.kind]) apply(node, fitted(node));
    });
  }

  let refit;
  window.addEventListener('resize', function () {
    clearTimeout(refit);
    refit = setTimeout(refitUnsaved, 100);
  });
  // </shared-table>

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
