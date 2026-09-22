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

## Read this before you run it

**This tool deletes source code based on a judgement it cannot make with
certainty. Use it at your own risk.**

It answers one question — *does anything reference this field?* — and static
analysis cannot answer that completely:

- **Dynamic access is invisible.** A field reached through `json['x']`,
  reflection, code generation, or a package you do not build from source looks
  unreferenced. Removing it compiles cleanly and breaks at runtime.
- **"Unused" is a claim about today's code.** A field nothing reads yet, but
  that a half-finished feature or another team's branch expects, will be
  reported.
- **The safety net only catches compile errors.** `remove` and `disable` run
  `dart analyze` and restore every file if an error appears — which catches a
  great deal, but nothing that still compiles and behaves differently. A field
  dropped from `toJson` changes the request body your server receives, and no
  analyzer will say so.

So: **commit or stash before running it, read the report rather than ticking
everything, and test the app afterwards.** `amscan disable` exists for exactly
this — comment the fields out, run the app, and `amscan disable --undo` if
anything misbehaves. Prefer it to `remove` until you trust the results on your
codebase.

### Only serialized classes are scanned

A class is treated as an API model only if it declares `fromJson` or `toJson`,
or extends one in the same file that does. Everything else is skipped and
counted in the scan output.

This matters because the tool's reasoning does not generalise. For a
serialized model, "nothing references this field" really does mean dead
weight, because serialization keeps it alive regardless of who reads it. For
an ordinary class the same silence can mean the field is reached through a
mixin, a callback, a subclass elsewhere, or a positional constructor — and
removing it is far more likely to be wrong.

The cost is a false negative: a genuine model that happens to declare neither
method is skipped, and its unused fields go unreported. If a class you expect
to see is missing from the report, that is the first thing to check.

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

### The optional editor

The first scan offers to install the VS Code editor, and remembers the answer.
You can also manage it directly:

```bash
amscan gui install     # Marketplace if reachable, otherwise the bundled copy
amscan gui uninstall
amscan gui status
```

It cannot ride along with `dart pub global activate`. Pub deliberately runs
**no** code when a package is activated or deactivated — that is what stops
any package installing things behind your back — so there is no hook to attach
to, and `dart pub global deactivate` cannot remove the editor either. Run
`amscan gui uninstall` first if you want it gone. Leaving it costs nothing: it
only claims files under `api_model_scanner/`, and does nothing without them.

`code` must be on PATH. In VS Code: Command Palette →
*Shell Command: Install 'code' command in PATH*.

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

`--models` also accepts a single `.dart` file, which keeps a scan to seconds
while you narrow something down:

```bash
amscan scan --models=lib/server/response/login/user_cover.dart
```

Only that file is indexed, so a subclass elsewhere forwarding a removed field
is not seen — the safety net still catches the result.

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

There is also a **VS Code editor** that renders the report as a real table
with checkbox cells, restricts editing to the checkboxes, and jumps to source
on click — see [editors/vscode](editors/vscode). The first scan offers to
install it; `amscan gui install` and `amscan gui uninstall` manage it after
that. It writes to the same Markdown file, so nothing depends on it being
installed.

Checkboxes are list items rather than table cells on purpose: GFM only makes
them interactive inside lists, in every mainstream preview. Toggling one in
Android Studio / IntelliJ writes `[x]` straight back to the file, which is all
the tool reads. VS Code's stock preview navigates links but does not toggle
checkboxes — type the `x` instead, or use the Markdown Preview Enhanced
extension.

Each row links twice, because no single link works everywhere:

| Link | Follows in | Lands on |
|---|---|---|
| **line N** | Android Studio / IntelliJ, VS Code | the file (often not the line) |
| **VS Code** | VS Code only | the exact line and column |

The relative link is also the only one that means anything off the machine
that wrote the report.

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
| `gui install` | Install the VS Code table editor (Marketplace, else bundled) |
| `gui uninstall` | Remove it — `dart pub global deactivate` cannot |
| `gui status` | Show whether it is installed, and what you answered |
| `clear` | Delete this project's cached results (keeps your settings) |

### Flags

| Flag | Commands | What it does |
|---|---|---|
| `--project` | `set-default` | Write the setting for this project instead of machine-wide |
| `--models=<dir>` | `scan`, `remove`, `disable` | Override the remembered default for one run |
| `--[no-]rescan` | `scan` | Answer the cached-results prompt up front |
| `--[no-]open` | `scan` | Open the report in your editor (default: on) |
| `--[no-]format` | `remove`, `disable` | Run `dart format` on modified files (default: on) |
| `-a`, `--accept-all` | `scan`, `remove`, `disable` | Answer every prompt affirmatively; never wait for input |
| `--all` | `remove`, `disable` | Act on everything, ignoring ticks |
| `--force` | `remove`, `disable` | Allow a dirty tree, and offer a rescan first |
| `--undo` | `disable` | Uncomment previously disabled fields |
| `--remove` | `disable` | Delete previously disabled fields for good |

`gui` takes subcommands rather than flags: `install`, `uninstall`, `status`.

`--undo` never needs `--force`: `disable` dirties the tree by construction, so
requiring a clean one would make undo unreachable exactly when you want it.
`--remove`, the only irreversible step, still asks for it.

With nothing ticked, `remove` and `disable` ask before acting on everything and
default to **No**. `--all` answers up front. With no terminal to ask on they
refuse rather than hang.

For an unattended run, `-a` answers *every* prompt — the cached-results offer,
the rescan after `--force`, and the nothing-ticked question, which it answers
the same way `--all` does:

```bash
amscan scan -a && amscan remove -a
```

It deliberately does **not** accept the offer to install the VS Code editor:
installing software is not part of the job you asked for, so that one is left
unanswered and asked again when someone is there to answer it.

## Files it writes

All under `.dart_tool/api_model_scanner/`, which git already ignores.

| File | Role |
|---|---|
| `config.json` | This project's models directory, if set. The machine-wide copy also holds your answer to the editor prompt |
| `unused_fields.json` | Machine-readable cache that `remove` and `disable` consume |
| `unused_fields.md` | The tickable report |
| `disabled_fields.json` | What is currently commented out |
| `disabled_fields.md` | Tickable record for `--undo` / `--remove` |

A record outlives its own contents while the *other* one still holds
something: `disable` empties the unused report, and `--undo` needs its header
— when the scan ran, and where — to hand the fields back. So after undoing, a
field is listed as unused again, in its original position, rather than
forgotten. Once both records are empty nothing is outstanding and both are
deleted; `clear` removes them at any time.

## Caveats

**Results are "potentially unused".** See the risks at the top of this file;
they are the point, not a footnote.

**Classes without `fromJson`/`toJson` are skipped**, so a model that declares
neither goes unreported. The scan output counts them.

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
