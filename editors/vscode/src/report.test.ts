import { strict as assert } from 'node:assert';
import { test } from 'node:test';

import {
  allBoxes,
  desiredStates,
  parseReport,
  readBox,
  setBox,
  toggleBox,
} from './report';

/**
 * Byte-for-byte the shape `ReportRenderer` emits, including the padded labels
 * and the two links per part row. If the Dart renderer changes, this fixture
 * is what should fail first.
 */
const REPORT = [
  '# Unused API model fields',
  '',
  '**2 fields** · **1 class** · scanned 2026-09-21 14:36 · 8 fields checked',
  '',
  'Tick what you want to act on, then run `amscan remove` to delete it.',
  '',
  '- [ ] **SELECT EVERYTHING**',
  '',
  '---',
  '',
  '## Rank',
  '',
  '└ [lib/server/response/rank.dart](../../lib/server/response/rank.dart)',
  '',
  '- [ ] **All of `Rank`**',
  '',
  '- [ ] **`rankEnName`** · 2 parts',
  '  - [ ] `field declaration               ` [line 9](../../lib/server/response/rank.dart#L9) · [VS Code](vscode://file/Users/me/app/lib/server/response/rank.dart:9:1)',
  '  - [x] `constructor parameter rankEnName` [line 19](../../lib/server/response/rank.dart#L19) · [VS Code](vscode://file/Users/me/app/lib/server/response/rank.dart:19:1)',
  '',
  '- [x] **`rankZhName`** · 1 part',
  '  - [ ] `field declaration` [line 10](../../lib/server/response/rank.dart#L10) · [VS Code](vscode://file/Users/me/app/lib/server/response/rank.dart:10:1)',
  '',
].join('\n');

test('reads the title and summary', () => {
  const report = parseReport(REPORT);
  assert.equal(report.title, 'Unused API model fields');
  assert.match(report.summary ?? '', /2 fields/);
});

test('reads the select-everything box', () => {
  const report = parseReport(REPORT);
  assert.equal(report.selectAll?.checked, false);
  assert.equal(report.selectAll?.line, 6);
});

test('groups fields under their class, with the class file', () => {
  const report = parseReport(REPORT);

  assert.equal(report.classes.length, 1);
  const block = report.classes[0];
  assert.equal(block.name, 'Rank');
  assert.equal(block.file, 'lib/server/response/rank.dart');
  assert.equal(block.checked, false);
  assert.deepEqual(
    block.fields.map((f) => f.name),
    ['rankEnName', 'rankZhName'],
  );
});

test('reads tick state on fields and parts independently', () => {
  const report = parseReport(REPORT);
  const [first, second] = report.classes[0].fields;

  assert.equal(first.checked, false);
  assert.deepEqual(
    first.parts.map((p) => p.checked),
    [false, true],
  );

  assert.equal(second.checked, true);
  assert.deepEqual(
    second.parts.map((p) => p.checked),
    [false],
  );
});

test('takes each part label without its padding', () => {
  const report = parseReport(REPORT);
  assert.deepEqual(
    report.classes[0].fields[0].parts.map((p) => p.label),
    ['field declaration', 'constructor parameter rankEnName'],
  );
});

test('takes the Dart file and line from the vscode link', () => {
  const report = parseReport(REPORT);
  const part = report.classes[0].fields[0].parts[1];

  assert.equal(part.file, '/Users/me/app/lib/server/response/rank.dart');
  assert.equal(part.sourceLine, 19);
});

test('a path with a space survives the round trip', () => {
  const encoded = REPORT.replace(/\/Users\/me\/app/g, '/Users/me/Mobile%20Dev');
  const report = parseReport(encoded);

  assert.equal(
    report.classes[0].fields[0].parts[0].file,
    '/Users/me/Mobile Dev/lib/server/response/rank.dart',
  );
});

test('a dead-class callout is recognised, not treated as a row', () => {
  const dead = REPORT.replace(
    '- [ ] **All of `Rank`**',
    '- [ ] **All of `Rank`**\n\n> 💀 **`Rank` is dead.** Every field is unused.',
  );
  const report = parseReport(dead);

  assert.equal(report.classes[0].dead, true);
  assert.equal(report.classes[0].fields.length, 2);
});

test('the class toggle is not mistaken for a field', () => {
  const report = parseReport(REPORT);
  assert.ok(!report.classes[0].fields.some((f) => f.name.includes('All of')));
});

test('every selectable row is reachable', () => {
  // 1 select-all + 1 class + 2 fields + 3 parts.
  assert.equal(allBoxes(parseReport(REPORT)).length, 7);
});

test('toggling flips exactly one character', () => {
  const edit = toggleBox(REPORT, 6);
  assert.ok(edit);
  assert.equal(edit.replacement, 'x');

  const lines = REPORT.split('\n');
  const before = lines[edit.line];
  const after =
    before.slice(0, edit.column) + edit.replacement + before.slice(edit.column + 1);

  assert.equal(after, '- [x] **SELECT EVERYTHING**');
  // Nothing but the box moved.
  assert.equal(after.length, before.length);
});

test('toggling a ticked box clears it', () => {
  const edit = toggleBox(REPORT, 18);
  assert.equal(edit?.replacement, ' ');
});

test('an indented part keeps its indentation when toggled', () => {
  const lines = REPORT.split('\n');
  const edit = toggleBox(REPORT, 17)!;
  const before = lines[17];
  const after =
    before.slice(0, edit.column) + edit.replacement + before.slice(edit.column + 1);

  assert.ok(after.startsWith('  - [x] `field declaration'));
  // The links and padding are untouched, which is what keeps the CLI parsing.
  assert.ok(after.includes('[VS Code](vscode://file'));
  assert.equal(after.length, before.length);
});

test('a line with no box yields no edit', () => {
  assert.equal(toggleBox(REPORT, 0), undefined);
  assert.equal(toggleBox(REPORT, 12), undefined);
});

test('an out-of-range line yields no edit', () => {
  assert.equal(toggleBox(REPORT, -1), undefined);
  assert.equal(toggleBox(REPORT, 9999), undefined);
});

test('an empty report parses to nothing rather than throwing', () => {
  const report = parseReport('# Unused API model fields\n\nNo unused model fields found. ✅\n');
  assert.equal(report.classes.length, 0);
  assert.equal(report.selectAll, undefined);
});

test('the disabled record parses with the same shapes', () => {
  const disabled = [
    '# Disabled API model fields',
    '',
    '- [ ] **SELECT EVERYTHING**',
    '',
    '---',
    '',
    '## Rank',
    '',
    '└ [lib/server/response/rank.dart](../../lib/server/response/rank.dart)',
    '',
    '- [ ] **All of `Rank`**',
    '',
    '- [ ] **`rankEnName`** · 2 snippets',
    '  - `String? rankEnName;`',
    '',
  ].join('\n');

  const report = parseReport(disabled);

  assert.equal(report.classes[0].name, 'Rank');
  assert.equal(report.classes[0].fields[0].name, 'rankEnName');
  // Snippet lines carry no checkbox, so they are not selectable parts.
  assert.equal(report.classes[0].fields[0].parts.length, 0);
});

/** Two classes, so cascades can be checked for leaking sideways. */
const TREE = [
  '# Unused API model fields',
  '',
  '- [ ] **SELECT EVERYTHING**',
  '',
  '## HomeAnnouncement',
  '',
  '- [ ] **All of `HomeAnnouncement`**',
  '',
  '- [ ] **`id`** · 2 parts',
  '  - [ ] `field declaration`',
  '  - [ ] `map entry`',
  '',
  '- [ ] **`endDate`** · 1 part',
  '  - [ ] `field declaration`',
  '',
  '## Image',
  '',
  '- [ ] **All of `Image`**',
  '',
  '- [ ] **`desktop`** · 1 part',
  '  - [ ] `field declaration`',
  '',
].join('\n');

const AT = {
  all: 2,
  homeClass: 6,
  id: 8,
  idDecl: 9,
  idMap: 10,
  endDate: 12,
  endDateDecl: 13,
  imageClass: 17,
  desktop: 19,
  desktopDecl: 20,
};

/** Applies a cascade to the text, the way the extension does. */
function apply(text: string, line: number, checked: boolean): string {
  const states = desiredStates(parseReport(text), line, checked);
  const lines = text.split('\n');
  for (const [at, want] of states) {
    const edit = setBox(lines.join('\n'), at, want);
    if (edit) {
      lines[at] =
        lines[at].slice(0, edit.column) +
        edit.replacement +
        lines[at].slice(edit.column + 1);
    }
  }
  return lines.join('\n');
}

const state = (text: string, line: number) => readBox(text, line);

test('cascade: ticking Select All ticks everything', () => {
  const out = apply(TREE, AT.all, true);
  for (const line of Object.values(AT)) {
    assert.equal(state(out, line), true, `line ${line} should be ticked`);
  }
});

test('cascade: ticking a class ticks its fields and parts only', () => {
  const out = apply(TREE, AT.homeClass, true);

  assert.equal(state(out, AT.homeClass), true);
  assert.equal(state(out, AT.id), true);
  assert.equal(state(out, AT.idDecl), true);
  assert.equal(state(out, AT.idMap), true);
  assert.equal(state(out, AT.endDate), true);
  assert.equal(state(out, AT.endDateDecl), true);

  // The other class is untouched, and so Select All stays off.
  assert.equal(state(out, AT.imageClass), false);
  assert.equal(state(out, AT.desktop), false);
  assert.equal(state(out, AT.all), false);
});

test('cascade: ticking a field ticks its parts', () => {
  const out = apply(TREE, AT.id, true);

  assert.equal(state(out, AT.id), true);
  assert.equal(state(out, AT.idDecl), true);
  assert.equal(state(out, AT.idMap), true);
  // Its sibling is untouched, so the class is not yet complete.
  assert.equal(state(out, AT.endDate), false);
  assert.equal(state(out, AT.homeClass), false);
});

test('cascade: a parent ticks only once every child is ticked', () => {
  let out = apply(TREE, AT.idDecl, true);
  assert.equal(state(out, AT.id), false, 'one of two parts is not enough');

  out = apply(out, AT.idMap, true);
  assert.equal(state(out, AT.id), true, 'both parts ticks the field');
  assert.equal(state(out, AT.homeClass), false, 'endDate is still outstanding');

  out = apply(out, AT.endDateDecl, true);
  assert.equal(state(out, AT.endDate), true);
  assert.equal(state(out, AT.homeClass), true, 'every field is now ticked');
  assert.equal(state(out, AT.all), false, 'Image is still outstanding');

  out = apply(out, AT.desktopDecl, true);
  assert.equal(state(out, AT.all), true, 'everything is ticked');
});

test('cascade: unticking a part unticks every ancestor', () => {
  const full = apply(TREE, AT.all, true);
  const out = apply(full, AT.idDecl, false);

  assert.equal(state(out, AT.idDecl), false);
  assert.equal(state(out, AT.id), false, 'the field is no longer whole');
  assert.equal(state(out, AT.homeClass), false, 'nor is the class');
  assert.equal(state(out, AT.all), false, 'nor is everything');

  // Only that one part moved; its siblings keep their state.
  assert.equal(state(out, AT.idMap), true);
  assert.equal(state(out, AT.endDate), true);
  assert.equal(state(out, AT.desktop), true);
});

test('cascade: unticking a field unticks its parts', () => {
  const full = apply(TREE, AT.all, true);
  const out = apply(full, AT.id, false);

  assert.equal(state(out, AT.idDecl), false);
  assert.equal(state(out, AT.idMap), false);
  assert.equal(state(out, AT.endDate), true, 'the sibling field is untouched');
  assert.equal(state(out, AT.homeClass), false);
});

test('cascade: unticking a class unticks everything under it', () => {
  const full = apply(TREE, AT.all, true);
  const out = apply(full, AT.homeClass, false);

  for (const line of [AT.id, AT.idDecl, AT.idMap, AT.endDate, AT.endDateDecl]) {
    assert.equal(state(out, line), false, `line ${line} should have cleared`);
  }
  assert.equal(state(out, AT.desktop), true, 'the other class survives');
});

test('cascade: unticking Select All clears the whole report', () => {
  const full = apply(TREE, AT.all, true);
  const out = apply(full, AT.all, false);

  for (const line of Object.values(AT)) {
    assert.equal(state(out, line), false, `line ${line} should have cleared`);
  }
});

test('cascade: a partially ticked parent reads as plainly unticked', () => {
  const out = apply(TREE, AT.idDecl, true);
  // No third state: the parent is simply false while a child is outstanding.
  assert.equal(state(out, AT.id), false);
  assert.equal(parseReport(out).classes[0].fields[0].checked, false);
});

test('cascade: a click on a line with no box changes nothing', () => {
  assert.equal(desiredStates(parseReport(TREE), 0, true).size, 0);
  assert.equal(apply(TREE, 0, true), TREE);
});

test('cascade: re-setting a box that is already right writes nothing', () => {
  assert.equal(setBox(TREE, AT.id, false), undefined);
  assert.equal(apply(TREE, AT.id, false), TREE);
});

const GUARDED_REPORT = [
  "# Unused API model fields",
  "",
  "**1 field** · **1 class** · **1 read dynamically** · scanned 2026-09-29 16:07 · 4 fields checked",
  "",
  "Tick what you want to act on, then run `amscan remove` to delete it or `amscan disable` to comment it out.",
  "",
  "Ticking a class or field selects everything under it. Ticking `field declaration` takes the whole field, since nothing else can reference a field that no longer exists. With nothing ticked, both commands offer to act on everything under SELECT EVERYTHING — never on the fields read dynamically, listed first.",
  "",
  "Every row links twice, because no single link works everywhere: **line N** is a relative path, which most editors will open, while **VS Code** is the form that lands the cursor on the exact line in the editor this scan was run from.",
  "",
  "---",
  "",
  "**⚠️ Read dynamically — taken only when you tick them**",
  "",
  "Nothing references these by type, but a field of the same name is read through a `dynamic` receiver — `for (final bank in list ?? [])` makes `bank` dynamic — and no reference search can follow that. Removing one still compiles, then throws `NoSuchMethodError` when the read runs.",
  "",
  "Matching is by name alone, since a dynamic receiver cannot say which class it holds, so some of these may be truly unused. Give each receiver a type and rescan — or tick a field here once you have checked it. SELECT EVERYTHING, a class tick and `--all` never reach this section.",
  "",
  "### DepositBank",
  "",
  "Declared in [lib/models/person.dart](../../lib/models/person.dart)",
  "",
  "* [ ] **`minAmount`** · 3 parts · read at [lib/app.dart:6](vscode://file/Users/me/app/lib/app.dart:6:1)",
  "  * [ ] `field declaration              ` [line 14](../../lib/models/person.dart#L14) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:14:1)",
  "  * [ ] `constructor parameter minAmount` [line 19](../../lib/models/person.dart#L19) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:19:1)",
  "  * [ ] `named argument minAmount       ` [line 25](../../lib/models/person.dart#L25) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:25:1)",
  "",
  "---",
  "",
  "**Unused — safe to select together**",
  "",
  "- [ ] **SELECT EVERYTHING**",
  "",
  "---",
  "",
  "## DepositBank",
  "",
  "└ [lib/models/person.dart](../../lib/models/person.dart)",
  "",
  "- [ ] **All of `DepositBank`**",
  "",
  "- [ ] **`branch`** · 3 parts",
  "  - [ ] `field declaration           ` [line 16](../../lib/models/person.dart#L16) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:16:1)",
  "  - [ ] `constructor parameter branch` [line 21](../../lib/models/person.dart#L21) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:21:1)",
  "  - [ ] `named argument branch       ` [line 27](../../lib/models/person.dart#L27) · [VS Code](vscode://file/Users/me/app/lib/models/person.dart:27:1)",
].join('\n');

/** Line of the first row whose text includes [needle]. */
const lineOf = (text: string, needle: string): number =>
  text.split('\n').findIndex((line) => line.includes(needle));

test('reads Select Everything when the guarded section comes before it', () => {
  // The guarded section is written first. A parser that stays in it until
  // the next class heading swallows the Select Everything row between them,
  // and the editor's Select All goes dead.
  const report = parseReport(GUARDED_REPORT);

  assert.ok(report.selectAll, 'Select Everything was not read');
  assert.equal(report.selectAll!.line, lineOf(GUARDED_REPORT, '**SELECT EVERYTHING**'));
  assert.ok(
    report.guarded[0].line < report.selectAll!.line,
    'fixture should have the guarded section first',
  );
});

test('keeps fields read dynamically apart from the rest', () => {
  const report = parseReport(GUARDED_REPORT);

  assert.deepEqual(
    report.classes.flatMap((c) => c.fields.map((f) => f.name)),
    ['branch'],
  );
  assert.deepEqual(
    report.guarded.flatMap((c) => c.fields.map((f) => f.name)),
    ['minAmount'],
  );
  assert.equal(report.title, 'Unused API model fields');
});

test('reads where a guarded field is read, and its parts', () => {
  const field = parseReport(GUARDED_REPORT).guarded[0].fields[0];

  assert.equal(field.parts.length, 3);
  assert.deepEqual(field.reads, [
    { label: 'lib/app.dart:6', file: '/Users/me/app/lib/app.dart', sourceLine: 6 },
  ]);
  assert.equal(parseReport(GUARDED_REPORT).guarded[0].file, 'lib/models/person.dart');
});

test('Select Everything never reaches the guarded section', () => {
  const report = parseReport(GUARDED_REPORT);
  const all = report.selectAll!.line;
  const states = desiredStates(report, all, true);
  const guarded = report.guarded[0].fields[0];

  assert.equal(states.get(guarded.line), false);
  for (const part of guarded.parts) {
    assert.equal(states.get(part.line), false);
  }
  // …while everything it does own is ticked.
  assert.equal(states.get(lineOf(GUARDED_REPORT, '**`branch`**')), true);
});

test('a class box never reaches the guarded section', () => {
  const report = parseReport(GUARDED_REPORT);
  const states = desiredStates(report, report.classes[0].line, true);

  assert.equal(states.get(report.guarded[0].fields[0].line), false);
});

test('ticking a guarded field ticks its parts, and nothing else', () => {
  const report = parseReport(GUARDED_REPORT);
  const field = report.guarded[0].fields[0];
  const states = desiredStates(report, field.line, true);

  assert.equal(states.get(field.line), true);
  for (const part of field.parts) {
    assert.equal(states.get(part.line), true);
  }
  assert.equal(states.get(report.selectAll!.line), false);
  assert.equal(states.get(report.classes[0].line), false);
});

test('ticking every guarded part settles its field, and nothing else', () => {
  let report = parseReport(GUARDED_REPORT);
  let text = GUARDED_REPORT;
  for (const part of report.guarded[0].fields[0].parts) {
    const edit = setBox(text, part.line, true)!;
    const lines = text.split('\n');
    const row = lines[edit.line];
    lines[edit.line] =
      row.slice(0, edit.column) + edit.replacement + row.slice(edit.column + 1);
    text = lines.join('\n');
  }
  report = parseReport(text);
  const last = report.guarded[0].fields[0].parts.at(-1)!;
  const states = desiredStates(report, last.line, true);

  assert.equal(states.get(report.guarded[0].fields[0].line), true);
  assert.equal(states.get(report.selectAll!.line), false);
});

test('an older report, with no guarded section, parses as before', () => {
  assert.deepEqual(parseReport(REPORT).guarded, []);
});

const DISABLED_REPORT = [
  "# Disabled API model fields",
  "",
  "**2 fields** commented out but still present in the source · 1 read dynamically.",
  "",
  "Tick what you want, then run `amscan disable --undo` to put it back or `amscan disable --remove` to delete it for good. With nothing ticked, both offer to act on everything — though `--remove` never takes a field read dynamically without a tick of its own.",
  "",
  "This file disappears once nothing is disabled.",
  "",
  "---",
  "",
  "**⚠️ Read dynamically — deleted for good only when you tick them**",
  "",
  "A field of the same name was read through a dynamic receiver when these were disabled, so the app may throw wherever that read runs until they are back. --undo puts them back along with everything else; --remove takes one only when it is ticked itself.",
  "",
  "### DepositBank",
  "",
  "Declared in [lib/models/person.dart](../../lib/models/person.dart)",
  "",
  "* [ ] **`minAmount`** · 3 snippets · read at [lib/app.dart:6](vscode://file/Users/me/app/lib/app.dart:6:1)",
  "  * `final double minAmount;`",
  "  * `required this.minAmount,`",
  "  * `minAmount: (json['minAmount'] as num).toDouble(),`",
  "",
  "---",
  "",
  "**Disabled — safe to select together**",
  "",
  "- [ ] **SELECT EVERYTHING**",
  "",
  "---",
  "",
  "## DepositBank",
  "",
  "└ [lib/models/person.dart](../../lib/models/person.dart)",
  "",
  "- [ ] **All of `DepositBank`**",
  "",
  "- [ ] **`branch`** · 3 snippets",
  "  - `final String branch;`",
  "  - `required this.branch,`",
  "  - `branch: json['branch'] as String,`",
].join('\n');

test('the disabled report: dynamic fields apart, with their own headings', () => {
  const report = parseReport(DISABLED_REPORT);

  assert.deepEqual(report.guarded.flatMap((c) => c.fields.map((f) => f.name)), ['minAmount']);
  assert.deepEqual(report.classes.flatMap((c) => c.fields.map((f) => f.name)), ['branch']);
  // Its own words, not the unused report's.
  assert.equal(report.mainTitle, 'Disabled — safe to select together');
  assert.match(report.guardedTitle ?? '', /deleted for good only when you tick them/);
  assert.match(report.guardedNote ?? '', /--undo puts them back/);
});

test('the disabled report: each field shows the code it had commented out', () => {
  // Snippet rows carry no checkbox, and were once read as nothing at all —
  // every disabled field showed "No removable declaration found".
  const report = parseReport(DISABLED_REPORT);
  const minAmount = report.guarded[0].fields[0];
  const branch = report.classes[0].fields[0];

  assert.equal(minAmount.snippets?.length, 3);
  assert.equal(branch.snippets?.[0], 'final String branch;');
  assert.deepEqual(minAmount.reads?.map((r) => r.label), ['lib/app.dart:6']);
});

test('the disabled report: a class keeps its file after the main heading', () => {
  // A heading's note is the first prose after it, and nothing further: the
  // class's file line must never be taken for one.
  assert.equal(parseReport(DISABLED_REPORT).classes[0].file, 'lib/models/person.dart');
});

test('the disabled report: Select Everything never reaches the guarded section', () => {
  const report = parseReport(DISABLED_REPORT);
  const states = desiredStates(report, report.selectAll!.line, true);

  assert.equal(states.get(report.guarded[0].fields[0].line), false);
  assert.equal(states.get(report.classes[0].fields[0].line), true);
});

test('the unused report names its own sections', () => {
  const report = parseReport(GUARDED_REPORT);

  assert.equal(report.mainTitle, 'Unused — safe to select together');
  assert.match(report.guardedTitle ?? '', /taken only when you tick them/);
});
