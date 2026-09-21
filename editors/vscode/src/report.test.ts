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
