## 1.0.3

`--version` reported 1.0.0 from both 1.0.1 and 1.0.2. The version is a
constant in `lib/src/version.dart`, because a globally activated snapshot
cannot read the pubspec it was built from — and a hand-kept copy of a fact
drifts the moment someone forgets it. A test now reads `pubspec.yaml` and
fails when the two disagree, so the release that forgets is the release
that does not build.

## 1.0.2

Editor prompts now name the editor rather than the command that drives it:
`VS Code (code)` instead of a bare `code`. The commands are this tool's
vocabulary, not yours — someone who has only ever launched the app has no
reason to know which of `code` and `code-insiders` is theirs. The command
stays in brackets, because it is what `--editor` takes.

The IntelliJ plugin tells you what to do when the IDE has no embedded
browser to draw the table in, instead of only that it has none. JCEF is
either switched off or absent from the runtime the IDE booted on, and the
two are fixed differently, so it names both.

## 1.0.1

Rebuilds the VS Code extension bundled in this package. It carries its own
copy of `package.json`, so it still named the repository's previous owner —
renaming a repository does not rebuild what was already packaged. The
extension's code is unchanged; only the manifest URLs move, and the bundled
build no longer ships its own `.gitignore`.

## 1.0.0

First release.

Finds API model fields your Flutter app never uses, by asking the Dart
analysis server who actually references each one, and removes them with
AST-aware source edits.

### Commands

- `init` sets the tool up, once, after installing — pub runs nothing on
  `activate`, so nothing can do it for you. It asks where your model classes
  live and reports how many it found there, so a wrong path shows up at once
  instead of at the next scan; it re-asks on a path it cannot use. It then
  picks the editor command when more than one is installed, and offers the
  report editor. `init --project` points one repo somewhere else, and wins
  over the machine-wide setting. A models directory is required: `scan`,
  `remove` and `disable` exit 78 rather than guess, since falling back to all
  of `lib` would treat every class in the app as an API model. The advice they
  print distinguishes never having run `init` from having run it and needing
  this project pointed.
- Every `init` answer can be a flag instead — `amscan init <dir>
  --editor=<command> --gui=yes|no` — so a provisioning script never needs a
  terminal. `-a` leaves anything unflagged unset rather than guessing, and
  installs nothing.
- `scan` writes a tickable Markdown report and opens it.
- `remove` deletes the ticked code, then strips imports left unused and
  deletes files left empty — keeping any file something still imports.
- `disable` comments the code out instead; `--undo` restores it and
  `--remove` deletes it for good.
- `uninstall` reverses `init`: the editor extension, both config files, this
  project's cached reports, then `pub global deactivate`. It refuses while any
  field is still commented out, because `disable` keeps the original source in
  the record rather than in the file — deleting it would strand that code
  looking perfectly fine. `--force` accepts that, `--keep-tool` leaves the
  command installed, `-y` skips the confirmation.
- Terminal output is sectioned and aligned, with paths shown relative to the
  project or against `~`. Styling switches itself off when output is not a
  terminal, and honours `NO_COLOR`, so logs stay plain.
- `clear` drops this project's cached results, keeping your settings. The
  records otherwise persist while either holds something, so `disable` then
  `--undo` returns a field to the unused report — in its original position —
  instead of losing it and forcing a rescan. Once both are empty, both go.

- `-a` / `--accept-all` answers every prompt affirmatively, for unattended
  runs. It implies `--all`. It installs nothing: the editor is offered by
  `init` and nowhere else, so a scan in CI never adds an extension to the
  build machine.

### The editors

- The link that lands the cursor on a line follows the editor the scan was run
  from. `vscode://` is a scheme only VS Code answers, so a report written from
  Android Studio carried a row that did nothing; it now carries the IDE's own
  open-file URL instead. Both editors' plugins read either form, so a report
  written in one is still navigable in the other.

- Android Studio gets the same table as a plugin. `init` offers one editor,
  chosen by the terminal it is run from: both IDEs name themselves in the
  environment, so it offers the plugin from Android Studio's terminal and the
  extension from VS Code's, whatever else is on the machine. With neither
  saying, VS Code and its forks come first. `gui install` and
  `gui uninstall` ask which editor to act on, so both can have it; `gui
  status` and `uninstall` cover both. A JetBrains IDE
  has no supported way to install a plugin from a local file on the command
  line, so this copies the unpacked plugin into the IDE's `plugins` directory
  the way the IDE itself would — which is why it is shipped unpacked rather
  than zipped. That directory is read only at startup, so anything
  written there — the plugin arriving or leaving — is invisible until the IDE
  goes round again. `gui install`, `gui uninstall` and `uninstall` all offer
  to restart it: a graceful quit, so open projects come back. The restart runs
  detached, since these are usually typed into the terminal of the very IDE
  being restarted.

- The editor command is configurable, so the VS Code forks work: they keep the
  same extension CLI, and since they use OpenVSX rather than the Marketplace,
  the copy that lands there is the `.vsix` bundled with this package. It also
  decides which editor opens the report, so window reuse works on a machine
  with no `code` on PATH.

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
