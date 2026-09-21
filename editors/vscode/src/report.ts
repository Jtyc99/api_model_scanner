/**
 * Reads an api_model_scanner report.
 *
 * The file this parses is the same Markdown the Dart CLI writes and reads
 * back, and the shapes below mirror `lib/src/cache/selection.dart` exactly.
 * Identity is structural — a `##` heading names the class, an unindented task
 * item names a field, and indented task items are that field's parts in order
 * — so nothing is hidden in the document and the two parsers cannot drift on
 * anything invisible.
 *
 * Deliberately free of any `vscode` import: everything here is a pure function
 * over text, which is what makes it testable without an editor host.
 */

/** A `- [x]` / `- [ ]` box, located precisely enough to rewrite in place. */
export interface Box {
  checked: boolean;
  /** 0-based line in the document. */
  line: number;
  /** Column of the `[` on that line. */
  column: number;
}

export interface Part extends Box {
  label: string;
  /** Absolute path of the Dart file, from the row's `vscode://` link. */
  file?: string;
  /** 1-based line in that Dart file. */
  sourceLine?: number;
}

export interface Field extends Box {
  name: string;
  parts: Part[];
}

export interface ClassBlock extends Box {
  name: string;
  /** Path as written in the class header, relative to the report. */
  file?: string;
  dead: boolean;
  fields: Field[];
}

export interface Report {
  title: string;
  /** The summary line under the title, if present. */
  summary?: string;
  selectAll?: Box;
  classes: ClassBlock[];
}

const HEADING = /^#{2}\s+(.+?)\s*$/;
const SELECT_ALL = /^\s*-\s*\[([ xX])\]\s*\*\*SELECT EVERYTHING\*\*/;
const CLASS_TOGGLE = /^-\s*\[([ xX])\]\s*\*\*All of\s*`([^`]+)`\*\*/;
const FIELD = /^-\s*\[([ xX])\]\s*\*\*`([^`]+)`\*\*/;
const PART = /^\s+-\s*\[([ xX])\]\s*`([^`]*)`/;
const CLASS_FILE = /^└\s*\[([^\]]+)\]/;
const VSCODE_LINK = /\]\(vscode:\/\/file([^:)]+):(\d+):\d+\)/;
const SUMMARY = /^\*\*\d+ fields?\*\*|^\*\*\d+ fields?\*\* ·/;

const ticked = (box: string): boolean => box.toLowerCase() === 'x';

/** Column of the `[` in a task item, so only the box itself gets rewritten. */
const boxColumn = (line: string): number => line.indexOf('[');

/**
 * Parses a report into classes, fields and parts.
 *
 * Unrecognised lines are ignored rather than rejected: the report carries
 * prose, rules and a dead-class callout, and none of it is selectable.
 */
export function parseReport(text: string): Report {
  const lines = text.split('\n');

  const report: Report = { title: 'API Model Scanner report', classes: [] };
  let currentClass: ClassBlock | undefined;
  let currentField: Field | undefined;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (line.startsWith('# ')) {
      report.title = line.slice(2).trim();
      continue;
    }

    if (!report.summary && SUMMARY.test(line)) {
      report.summary = line.replace(/\*\*/g, '').trim();
      continue;
    }

    const heading = HEADING.exec(line);
    if (heading) {
      currentClass = {
        name: heading[1],
        checked: false,
        line: i,
        column: -1,
        dead: false,
        fields: [],
      };
      currentField = undefined;
      report.classes.push(currentClass);
      continue;
    }

    if (currentClass) {
      const file = CLASS_FILE.exec(line);
      if (file) {
        currentClass.file = file[1];
        continue;
      }
      if (line.startsWith('> 💀')) {
        currentClass.dead = true;
        continue;
      }
    }

    const selectAll = SELECT_ALL.exec(line);
    if (selectAll) {
      report.selectAll = {
        checked: ticked(selectAll[1]),
        line: i,
        column: boxColumn(line),
      };
      continue;
    }

    // Before FIELD: `**All of \`X\`**` would not match FIELD anyway, since
    // that needs a backtick straight after `**` — but order makes it certain.
    const classToggle = CLASS_TOGGLE.exec(line);
    if (classToggle && currentClass) {
      currentClass.checked = ticked(classToggle[1]);
      currentClass.column = boxColumn(line);
      currentClass.line = i;
      continue;
    }

    const field = FIELD.exec(line);
    if (field && currentClass) {
      currentField = {
        name: field[2],
        checked: ticked(field[1]),
        line: i,
        column: boxColumn(line),
        parts: [],
      };
      currentClass.fields.push(currentField);
      continue;
    }

    const part = PART.exec(line);
    if (part && currentField) {
      const link = VSCODE_LINK.exec(line);
      currentField.parts.push({
        label: part[2].trim(),
        checked: ticked(part[1]),
        line: i,
        column: boxColumn(line),
        file: link ? decodeURIComponent(link[1]) : undefined,
        sourceLine: link ? Number(link[2]) : undefined,
      });
    }
  }

  return report;
}

/** A single-character rewrite: the smallest edit that flips one box. */
export interface BoxEdit {
  line: number;
  /** Column of the character between the brackets. */
  column: number;
  replacement: 'x' | ' ';
}

/**
 * The edit that flips the box at [line].
 *
 * Only the character inside the brackets is replaced, so a toggle can never
 * disturb the row's text, links or alignment — which is the whole reason the
 * CLI can keep parsing a file the webview has written to.
 */
export function toggleBox(text: string, line: number): BoxEdit | undefined {
  const lines = text.split('\n');
  if (line < 0 || line >= lines.length) {
    return undefined;
  }

  const source = lines[line];
  const open = source.indexOf('[');
  if (open === -1 || source.length < open + 3 || source[open + 2] !== ']') {
    return undefined;
  }

  const current = source[open + 1];
  if (current !== ' ' && current.toLowerCase() !== 'x') {
    return undefined;
  }

  return {
    line,
    column: open + 1,
    replacement: current === ' ' ? 'x' : ' ',
  };
}

/** Every box the report declares, for select-all style operations. */
export function allBoxes(report: Report): Box[] {
  const boxes: Box[] = [];
  if (report.selectAll) {
    boxes.push(report.selectAll);
  }
  for (const block of report.classes) {
    if (block.column >= 0) {
      boxes.push(block);
    }
    for (const field of block.fields) {
      boxes.push(field);
      boxes.push(...field.parts);
    }
  }
  return boxes;
}
