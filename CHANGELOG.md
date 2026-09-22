## 1.0.0

First release.

Finds API model fields your Flutter app never uses, by asking the Dart
analysis server who actually references each one, and removes them with
AST-aware source edits.

### Commands

- `set-default <dir>` remembers where your API models live, machine-wide or —
  with `--project` — for one repo, which wins over it. Required once: `scan`,
  `remove` and `disable` exit 78 rather than guess, since falling back to all
  of `lib` would treat every class in the app as an API model.
- `scan` writes a tickable Markdown report and opens it.
- `remove` deletes the ticked code, then strips imports left unused and
  deletes files left empty — keeping any file something still imports.
- `disable` comments the code out instead; `--undo` restores it and
  `--remove` deletes it for good.
- `clear` drops this project's cached results, keeping your settings. The
  records otherwise persist while either holds something, so `disable` then
  `--undo` returns a field to the unused report — in its original position —
  instead of losing it and forcing a rescan. Once both are empty, both go.

- `-a` / `--accept-all` answers every prompt affirmatively, for unattended
  runs. It implies `--all`, and accepts the first-run offer to install the
  VS Code editor.

### Detection

- Accessor-aware: a field stored privately and published through a getter is
  reached by that getter, so counting only the field would mark every such
  field in the project unused.
- Only classes that declare `fromJson`/`toJson`, or extend one in the same
  file that does, are treated as API models. The reasoning — that
  serialization keeps a field alive regardless of who reads it — does not
  hold for an ordinary class.
- References from inside a model's own file are serialization, not usage.

### Rewriting

- `==` and `hashCode` chains are cut per contiguous run, so removing a prefix
  cannot leave a dangling operator.
- A member whose every term is removed goes with them, rather than becoming a
  syntax error.
- An optional parameter group that empties loses its `{}`, which Dart does not
  allow to be empty.
- Subclasses give up the `super.field` parameters they forward, including
  subclasses in other files — a resolution error that parses cleanly, so only
  `dart analyze` would otherwise catch it.
- Classes left dead by a removal are resolved to a fixpoint and taken whole.

### Safety

- After writing, `remove` and `disable` run `dart analyze` and restore every
  file if an error appears. It fails closed: if verification cannot run, it
  reverts.
- Both refuse a dirty git working tree, so `git diff` always shows exactly
  what the tool did. `--undo` is exempt, since `disable` dirties the tree by
  construction.
- `disabled_fields.json` anchors each commented range to its position in the
  file, not just its text, so two byte-identical ranges are restored
  separately.
- Undoing part of a class holds back ranges shared with fields that are not
  selected, and names the ones to tick.

### Editor

- A VS Code custom editor renders the report as a real table with checkbox
  cells — see `editors/vscode`. It writes to the same Markdown, so nothing
  depends on it being installed.
- The first scan offers to install it and remembers the answer;
  `amscan gui install`, `gui uninstall` and `gui status` manage it after that.
  Installing prefers the Marketplace and falls back to the copy shipped in
  this package. It cannot be attached to `dart pub global activate` or
  `deactivate`: pub runs no code on either, by design.
