# api_model_scanner

A Dart CLI that finds API model fields your Flutter app never uses, then
removes them — or comments them out first, if you would rather look before you
leap.

Generated model classes accumulate fields the app stopped reading years ago.
They are invisible to the compiler, because `fromJson` and `toJson` keep every
one of them alive. This tool asks the Dart analysis server who *actually*
references each field, and reports the ones nobody does.

```
amscan set-default lib/server/response   # once
amscan scan                              # find them, tick what you want
amscan remove                            # delete the ticked code
```

## Why not just grep

`grep giftList` finds the declaration, the constructor, `fromJson`, `toJson`,
`==`, `hashCode` — and cannot tell any of them apart from a real use. Worse, it
misses the case that matters most:

```dart
GiftList? _giftList;                   // zero external references
GiftList? get giftList => _giftList;   // the actual public API
```

Counting references to `_giftList` alone marks every privately-stored field in
the project as unused. This tool maps each field to the public members that
expose it and counts those too. References from inside the model's own file
are ignored, because serialization is not usage.

Removal is AST-aware: exact source ranges are deleted, never regex matches. It
understands that `==` and `hashCode` chains need their operators rejoined, that
`Tabs({})` is a syntax error so an emptied parameter group loses its braces,
and that a getter whose every term is gone has to go with them.

## Install

```bash
dart pub global activate --source git https://github.com/JtycEdgeTech/api_model_scanner.git
```

`api_model_scanner` and `amscan` are the same executable.

> **Never add this package to a Flutter app's `pubspec.yaml`.** It needs
> `analyzer ^14`, which requires `meta ^1.18.3`, while the Flutter SDK pins
> `meta 1.17.0`. Version solving fails. Global activation resolves it in
> isolation, so the CLI still works from inside any Flutter project.

While developing the tool itself, run it directly and skip activation:

```bash
dart run /abs/path/to/api_model_scanner/bin/api_model_scanner.dart scan
```

Path activation is best avoided: a space anywhere in the checkout path
(`Mobile Dev`) makes pub emit a launcher whose `[ -f … ]` test is unquoted, so
every run silently falls back to `dart pub global run` and re-resolves
dependencies. Path-activated packages also do not pick up edits — re-running
`activate` does not rebuild the snapshot; delete
`.dart_tool/pub/bin/api_model_scanner/*.snapshot`.

## Setting up

Run this once so you do not have to pass `--models` every time:

```bash
amscan set-default lib/server/response
```

That is machine-wide. For a repo that keeps its models elsewhere:

```bash
amscan set-default lib/api/models --project
```

A project setting wins over the machine-wide one, and `--models=<dir>` beats
both for a single run.

| Scope | Where it lives |
|---|---|
| Machine-wide | `$XDG_CONFIG_HOME/api_model_scanner/config.json`, else `~/.config/…` (`%APPDATA%` on Windows) |
| One project | `.dart_tool/api_model_scanner/config.json` |

The project file sits in `.dart_tool/`, which Dart projects already ignore, so
remembering a directory never dirties your working tree. `clear` leaves it
alone — it is a setting, not a cached result.

With nothing set, those commands exit with code 78 and tell you what to run.
`set-default`, `clear`, and `disable --undo` / `--remove` work regardless —
the last two act on the disabled record, which already names its own files.

## The workflow

**`amscan scan`** resolves references, writes a report, and opens it.

**Tick what you want to lose.** `unused_fields.md` is a normal Markdown file
with GFM task lists — click the checkboxes in your editor's preview, or type
`x`. Tick a field to take it whole, or tick individual parts to take only
those.

**`amscan remove`** deletes the ticked code, then tidies imports that are no
longer used and deletes files left empty.

**`amscan disable`** comments it out instead, so you can run the app and see
what breaks. `--undo` puts it back; `--remove` deletes it for good.

Both refuse to run on a dirty git working tree, so `git diff` always shows
exactly what the tool did and `git checkout .` always undoes it.

### Safety net

After writing, `remove` and `disable` run `dart analyze` on what they wrote and
**restore every file** if a single error-severity diagnostic appears. It fails
closed: if verification cannot run at all, it reverts.

This matters because model classes come in shapes the fixer does not fully
understand. When it meets one, you get your code back and a message, rather
than a broken build.

## Commands

| Command | What it does |
|---|---|
| `set-default <dir>` | Remember where your models live |
| `scan` | Find unused fields, write and open the report |
| `remove` | Delete ticked code, then tidy imports and empty files |
| `disable` | Comment out ticked code, or `--undo` / `--remove` what is commented |
| `clear` | Delete this project's cached results (keeps your settings) |

### Flags

| Flag | Commands | What it does |
|---|---|---|
| `--project` | `set-default` | Write the setting for this project instead of machine-wide |
| `--models=<dir>` | `scan`, `remove`, `disable` | Override the remembered default for one run |
| `--[no-]rescan` | `scan` | Answer the cached-results prompt up front |
| `--[no-]open` | `scan` | Open the report in your editor (default: on) |
| `--[no-]format` | `remove`, `disable` | Run `dart format` on modified files (default: on) |
| `--all` | `remove`, `disable` | Act on everything, ignoring ticks |
| `--force` | `remove`, `disable` | Allow a dirty tree, and offer a rescan first |
| `--undo` | `disable` | Uncomment previously disabled fields |
| `--remove` | `disable` | Delete previously disabled fields for good |

`--undo` never needs `--force`: `disable` dirties the tree by construction, so
requiring a clean one would make undo unreachable exactly when you want it.
`--remove`, the only irreversible step, still asks for it.

With nothing ticked, `remove` and `disable` ask before acting on everything and
default to **No**. `--all` answers up front. With no terminal to ask on they
refuse rather than hang.

## Files it writes

All under `.dart_tool/api_model_scanner/`, which git already ignores.

| File | Role |
|---|---|
| `config.json` | This project's models directory, if set |
| `unused_fields.json` | Machine-readable cache that `remove` and `disable` consume |
| `unused_fields.md` | The tickable report |
| `disabled_fields.json` | What is currently commented out |
| `disabled_fields.md` | Tickable record for `--undo` / `--remove` |

The `disabled_*` pair exists only while something is disabled, and deletes
itself once nothing is.

## Caveats

**Results are "potentially unused".** Anything reached dynamically —
`json['x']`, reflection, a field read only by a package you do not build from
source — is invisible to static analysis. Read the report before ticking.

**Generated files are not rewritten.** `*.g.dart` and freezed partials are left
alone; regenerate them instead.

**Some model shapes are not understood.** Hand-rolled constructor-body
assignment and map-literal serialization are handled, including the
private-field/getter style. Anything else trips the safety net and reverts.

**Removing `hashCode` while `==` survives** leaves a `hash_and_equals` lint.
The safety net only blocks on errors, so this passes with a warning.

**Undo matches recorded code exactly.** Hand-editing inside a disabled comment
means that field is skipped with a message rather than mangled.

**Undoing part of a class may hold back.** Fields sharing one commented range —
a `hashCode` naming all of them — move together or not at all, because
restoring it while some are still commented would not compile. The tool names
the fields you also need to tick.

**The report cannot be read-only.** Toggling a checkbox *is* a text edit, so
"text uneditable, checkboxes clickable" is impossible in Markdown. Only
checkbox state is read, and `scan` regenerates the file, so stray edits are
harmless.

## Development

```bash
dart test
dart analyze
```
