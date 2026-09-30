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

/** Somewhere a field of this name is read through a `dynamic` receiver. */
export interface Read {
  /** As the report writes it, e.g. `lib/app.dart:6`. */
  label: string;
  /** Absolute path, from the read's `vscode://` link. */
  file?: string;
  /** 1-based. */
  sourceLine?: number;
}

export interface Field extends Box {
  name: string;
  parts: Part[];
  /** Set only on fields in the guarded section. */
  reads?: Read[];
  /**
   * The disabled report's rows: code that was commented out, listed without
   * checkboxes because a field moves back whole or not at all.
   */
  snippets?: string[];
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
  /**
   * Fields that look unused but are read through `dynamic` somewhere, so
   * removing one compiles and then throws. Kept out of [classes] on purpose:
   * nothing that cascades — Select Everything, a class box — ever reaches
   * them. Only a tick on the field or one of its parts does.
   */
  guarded: ClassBlock[];
  /** The headings the report gives each section, when it gives them. */
  guardedTitle?: string;
  mainTitle?: string;
  /** The first paragraph under the guarded section's heading. */
  guardedNote?: string;
}

const HEADING = /^#{2}\s+(.+?)\s*$/;
const SELECT_ALL = /^\s*-\s*\[([ xX])\]\s*\*\*SELECT EVERYTHING\*\*/;
const CLASS_TOGGLE = /^-\s*\[([ xX])\]\s*\*\*All of\s*`([^`]+)`\*\*/;
const FIELD = /^-\s*\[([ xX])\]\s*\*\*`([^`]+)`\*\*/;
const PART = /^\s+-\s*\[([ xX])\]\s*`([^`]*)`/;
const CLASS_FILE = /^└\s*\[([^\]]+)\]/;
const VSCODE_LINK = /\]\(vscode:\/\/file([^:)]+):(\d+):\d+\)/;

// The guarded section is written in shapes the patterns above do not match —
// `###`, `*` bullets, `Declared in` — so an editor released before it existed
// cannot take its rows for ordinary ones and tick them from Select Everything.
const GUARDED_HEADING = /^#{3}\s+(.+?)\s*$/;
const GUARDED_FILE = /^Declared in \[([^\]]+)\]/;
const GUARDED_FIELD = /^\*\s*\[([ xX])\]\s*\*\*`([^`]+)`\*\*/;
const GUARDED_PART = /^\s+\*\s*\[([ xX])\]\s*`([^`]*)`/;
const READ_LINK = /\[([^\]]+)\]\(vscode:\/\/file([^:)]+):(\d+):\d+\)/g;
// A line that is nothing but bold text heads a section: the CLI words it for
// the report it is writing, so the editor shows that rather than guessing.
const BANNER = /^\*\*([^*].*?)\*\*\s*$/;
// A disabled field's code, one line per commented-out range, with no box.
const SNIPPET = /^\s+[-*]\s+`(.*)`\s*$/;
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

  const report: Report = {
    title: 'API Model Scanner report',
    classes: [],
    guarded: [],
  };
  let currentClass: ClassBlock | undefined;
  let currentField: Field | undefined;
  let inGuarded = false;
  // A heading waits here until the section it names begins.
  let banner: string | undefined;
  let note: string | undefined;
  let awaitingNote = false;
  const snippetOf = (line: string): boolean => {
    const snippet = SNIPPET.exec(line);
    if (snippet && currentField) {
      (currentField.snippets ??= []).push(snippet[1]);
      return true;
    }
    return false;
  };

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

    // Read before anything that depends on the section: the guarded section
    // sits above it, and Select Everything is what closes that section.
    const selectAll = SELECT_ALL.exec(line);
    if (selectAll) {
      report.selectAll = {
        checked: ticked(selectAll[1]),
        line: i,
        column: boxColumn(line),
      };
      inGuarded = false;
      currentClass = undefined;
      currentField = undefined;
      if (banner && report.mainTitle === undefined) {
        report.mainTitle = banner;
      }
      banner = undefined;
      // The main table has no note to wait for.
      awaitingNote = false;
      continue;
    }

    // Also ahead of the guarded section's own lines: the main table's heading
    // sits between that section and Select Everything.
    const bannerLine = BANNER.exec(line);
    if (bannerLine && !SELECT_ALL.test(line)) {
      banner = bannerLine[1].trim();
      note = undefined;
      awaitingNote = true;
      continue;
    }
    if (awaitingNote && line.trim() && !line.startsWith('#') &&
        !line.startsWith('---')) {
      note = line.replace(/`/g, '').trim();
      awaitingNote = false;
      continue;
    }

    const heading = HEADING.exec(line);
    const guardedHeading = heading ? null : GUARDED_HEADING.exec(line);
    if (heading || guardedHeading) {
      inGuarded = guardedHeading !== null;
      awaitingNote = false;
      if (inGuarded && report.guardedTitle === undefined && banner) {
        report.guardedTitle = banner;
        report.guardedNote = note;
        banner = undefined;
      }
      currentClass = {
        name: (heading ?? guardedHeading)![1],
        checked: false,
        line: i,
        column: -1,
        dead: false,
        fields: [],
      };
      currentField = undefined;
      (inGuarded ? report.guarded : report.classes).push(currentClass);
      continue;
    }

    if (inGuarded && currentClass) {
      const file = GUARDED_FILE.exec(line);
      if (file) {
        currentClass.file = file[1];
        continue;
      }

      const field = GUARDED_FIELD.exec(line);
      if (field) {
        currentField = {
          name: field[2],
          checked: ticked(field[1]),
          line: i,
          column: boxColumn(line),
          parts: [],
          reads: [...line.matchAll(READ_LINK)].map((m) => ({
            label: m[1],
            file: decodeURIComponent(m[2]),
            sourceLine: Number(m[3]),
          })),
        };
        currentClass.fields.push(currentField);
        continue;
      }

      if (snippetOf(line)) {
        continue;
      }

      const part = GUARDED_PART.exec(line);
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
      continue;
    }

    snippetOf(line);
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
  const current = readBox(text, line);
  if (current === undefined) {
    return undefined;
  }
  return setBox(text, line, !current);
}

/** Whether the box on [line] is ticked, or undefined when there is none. */
export function readBox(text: string, line: number): boolean | undefined {
  const lines = text.split('\n');
  if (line < 0 || line >= lines.length) {
    return undefined;
  }
  const source = lines[line];
  const open = source.indexOf('[');
  if (open === -1 || source.length < open + 3 || source[open + 2] !== ']') {
    return undefined;
  }
  const value = source[open + 1];
  if (value === ' ') {
    return false;
  }
  if (value.toLowerCase() === 'x') {
    return true;
  }
  return undefined;
}

/**
 * The edit that puts the box on [line] into [checked], or undefined when it is
 * already there — so a cascade only writes what actually moves.
 */
export function setBox(
  text: string,
  line: number,
  checked: boolean,
): BoxEdit | undefined {
  const current = readBox(text, line);
  if (current === undefined || current === checked) {
    return undefined;
  }

  const open = text.split('\n')[line].indexOf('[');
  return { line, column: open + 1, replacement: checked ? 'x' : ' ' };
}

/** Which row a box belongs to, and where it sits in the tree. */
export interface Located {
  kind: 'all' | 'class' | 'field' | 'part';
  classIndex?: number;
  fieldIndex?: number;
  /** Indices point into `report.guarded` rather than `report.classes`. */
  guarded?: boolean;
}

/** Finds the box on [line], or undefined when that line holds none. */
export function locate(report: Report, line: number): Located | undefined {
  if (report.selectAll?.line === line) {
    return { kind: 'all' };
  }
  for (let c = 0; c < report.classes.length; c++) {
    const block = report.classes[c];
    if (block.column >= 0 && block.line === line) {
      return { kind: 'class', classIndex: c };
    }
    for (let f = 0; f < block.fields.length; f++) {
      const field = block.fields[f];
      if (field.line === line) {
        return { kind: 'field', classIndex: c, fieldIndex: f };
      }
      if (field.parts.some((part) => part.line === line)) {
        return { kind: 'part', classIndex: c, fieldIndex: f };
      }
    }
  }
  for (let c = 0; c < report.guarded.length; c++) {
    const fields = report.guarded[c].fields;
    for (let f = 0; f < fields.length; f++) {
      if (fields[f].line === line) {
        return { kind: 'field', classIndex: c, fieldIndex: f, guarded: true };
      }
      if (fields[f].parts.some((part) => part.line === line)) {
        return { kind: 'part', classIndex: c, fieldIndex: f, guarded: true };
      }
    }
  }
  return undefined;
}

/**
 * The state every box should hold after setting the one on [line].
 *
 * Two rules, and the second follows from the first:
 *
 *   * Setting a box sets everything under it — tick a field and its parts go
 *     with it, because selecting a field means selecting all of it.
 *   * A parent is ticked exactly when all of its children are. So unticking
 *     one part unticks its field, its class and Select Everything, and
 *     ticking the last outstanding part ticks them all back.
 *
 * Deriving the parent rather than storing it is what makes the two consistent
 * by construction: there is no state in which a field is ticked while one of
 * its parts is not.
 */
export function desiredStates(
  report: Report,
  line: number,
  checked: boolean,
): Map<number, boolean> {
  const target = locate(report, line);
  if (!target) {
    return new Map();
  }

  const state = new Map<number, boolean>();
  for (const box of allBoxes(report)) {
    state.set(box.line, box.checked);
  }

  const setField = (field: Field) => {
    state.set(field.line, checked);
    for (const part of field.parts) {
      state.set(part.line, checked);
    }
  };

  const setClass = (block: ClassBlock) => {
    if (block.column >= 0) {
      state.set(block.line, checked);
    }
    block.fields.forEach(setField);
  };

  switch (target.kind) {
    case 'all':
      if (report.selectAll) {
        state.set(report.selectAll.line, checked);
      }
      report.classes.forEach(setClass);
      break;
    case 'class':
      setClass(report.classes[target.classIndex!]);
      break;
    case 'field': {
      const blocks = target.guarded ? report.guarded : report.classes;
      setField(blocks[target.classIndex!].fields[target.fieldIndex!]);
      break;
    }
    case 'part':
      state.set(line, checked);
      break;
  }

  // Now settle every parent from the bottom up. A field with no parts of its
  // own — one whose declaration could not be found — keeps whatever it was
  // given, since there is nothing beneath it to derive from.
  for (const block of report.classes) {
    for (const field of block.fields) {
      if (field.parts.length > 0) {
        state.set(
          field.line,
          field.parts.every((part) => state.get(part.line) === true),
        );
      }
    }
    if (block.column >= 0 && block.fields.length > 0) {
      state.set(
        block.line,
        block.fields.every((field) => state.get(field.line) === true),
      );
    }
  }

  // A guarded field follows its own parts, and nothing follows it: it has no
  // class box, and it never counts toward Select Everything.
  for (const block of report.guarded) {
    for (const field of block.fields) {
      if (field.parts.length > 0) {
        state.set(
          field.line,
          field.parts.every((part) => state.get(part.line) === true),
        );
      }
    }
  }

  if (report.selectAll) {
    const tickable = report.classes.filter((block) => block.column >= 0);
    if (tickable.length > 0) {
      state.set(
        report.selectAll.line,
        tickable.every((block) => state.get(block.line) === true),
      );
    }
  }

  return state;
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
  for (const block of report.guarded) {
    for (const field of block.fields) {
      boxes.push(field);
      boxes.push(...field.parts);
    }
  }
  return boxes;
}
