# api_model_scanner

A Dart CLI that finds API model fields your Flutter app never uses, then
removes them — or comments them out first, if you would rather look before you
leap.

Generated model classes accumulate fields the app stopped reading years ago.
They are invisible to the compiler, because `fromJson` and `toJson` keep every
one of them alive. This tool asks the Dart analysis server who *actually*
references each field, and reports the ones nobody does.

```
amscan init      # once, after installing — answers where and with what
amscan scan      # find them, tick what you want
amscan remove    # delete the ticked code
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
dart pub global activate api_model_scanner
```

`api_model_scanner` and `amscan` are the same executable.

To track unreleased changes, install from the repository instead:

```bash
dart pub global activate --source git https://github.com/Jtyc99/api_model_scanner.git
```

## Updating

```bash
dart pub global activate api_model_scanner
```

The same command as installing. There is no `pub global upgrade` for a
single package — re-activating *is* the update, and it replaces whatever
version was there.

`scan` checks pub.dev at most once a day and prints one line when a newer
release exists. It never blocks: it gives up after two seconds, says nothing
when offline, and `-a` skips it so an unattended run never reaches for the
network. Set `AMSCAN_NO_UPDATE_CHECK` to anything to turn it off for good.

**The editors update separately.** Updating the command does not touch an
extension or plugin already installed — those come from their marketplaces,
or from `amscan gui install` if you want the copy bundled with this package.

| What | How it updates |
|---|---|
| The `amscan` command | `dart pub global activate api_model_scanner` |
| VS Code extension | VS Code, from the Marketplace |
| Android Studio plugin | The IDE, from JetBrains Marketplace |
| Either, from the bundle | `amscan gui install` |

### The optional editor

`init` offers to install it and remembers the answer. You can also manage it
directly:

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

Run `init` once after installing. Pub runs nothing on `activate` — by design —
so nothing can do this for you:

```bash
amscan init
```

It asks where your API model classes live — a directory, or one `.dart` file,
relative to the project root — and says how many model classes it found there,
so a wrong path shows up immediately rather than at the next scan. It re-asks
on a path it cannot use. It then asks which editor command to use if more than
one is installed, and offers the report editor.

For a repo that keeps its models somewhere else:

```bash
amscan init --project
```

A project setting wins over the machine-wide one, and `--models=<dir>` beats
both for a single run. If your projects have nothing in common, answer
*"skip — I'll set it per project"* to the first question and use
`init --project` in each.

Nothing here has to be interactive. Every answer can be a flag, which is what
a provisioning script or a CI job should use:

```bash
amscan init lib/server/response --editor=code --gui=no
```

`-a` never waits for input, and leaves anything you did not pass as a flag
unset rather than guessing — in particular it installs nothing.

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

With nothing set, those commands exit with code 78 and tell you what to run —
`amscan init` if you have never run it, `amscan init --project` if you have
and this project is the one that needs pointing. `init`, `gui`, `clear`, and
`disable --undo` / `--remove` work regardless; the last two act on the
disabled record, which already names its own files.

The machine-wide file also holds which editor command to drive and whether
you wanted the report editor. Those are facts about the machine, not the
repository, so `init --project` never writes them.

## The workflow

**`amscan scan`** resolves references, writes a report, and opens it.

**Tick what you want to lose.** `unused_fields.md` is a normal Markdown file
with GFM task lists — click the checkboxes in your editor's preview, or type
`x`. Tick a field to take it whole, or tick individual parts to take only
those.

There is also a **VS Code editor** that renders the report as a real table
with checkbox cells, restricts editing to the checkboxes, and jumps to source
on click — see [editors/vscode](editors/vscode). `init` offers to install it;
`amscan gui install` and `amscan gui uninstall` manage it after that. It
writes to the same Markdown file, so nothing depends on it being installed.

**Android Studio** gets the same table, as an IntelliJ plugin — see
[editors/intellij](editors/intellij). `.vsix` is VS Code's format and could
never load there, so it is a separate build. `init` offers whichever editor you
are most likely to be using. Both IDEs name themselves in their terminal's
environment, so running `amscan init` from Android Studio's terminal offers
the plugin and running it from VS Code's offers the extension — whatever else
is installed on the machine. Failing that, VS Code and its forks come first.
`gui install` asks which, so you can have both. A JetBrains
IDE only notices a new plugin when it restarts.

It works in the VS Code forks too. They keep the same extension CLI, so
`--editor=cursor` or `--editor=windsurf` drives them; because they use OpenVSX
rather than the VS Code Marketplace, the copy that lands there is the `.vsix`
bundled with this package.

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
| `init` | Set up the tool — models directory, editor, report editor |
| `init --project` | Set the models directory for this project only |
| `init <dir>` | Set the models directory without being asked for it |
| `scan` | Find unused fields, write and open the report |
| `remove` | Delete ticked code, then tidy imports and empty files |
| `disable` | Comment out ticked code, or `--undo` / `--remove` what is commented |
| `gui install` | Install the table editor — asks which editor or IDE |
| `gui uninstall` | Remove it — asks which editor or IDE |
| `gui status` | Show whether it is installed, and what you answered |
| `clear` | Delete this project's cached results (keeps your settings) |
| `uninstall` | Remove the editor, every setting, and the tool itself |

### Flags

| Flag | Commands | What it does |
|---|---|---|
| `--project` | `init` | Write the setting for this project instead of machine-wide |
| `--editor=<cmd>` | `init` | Which editor command to drive (`code`, `cursor`, `windsurf`, `code-insiders`) |
| `--gui=yes\|no` | `init` | Answer the report-editor question without being asked |
| `--models=<dir>` | `scan`, `remove`, `disable` | Override the remembered default for one run |
| `--[no-]rescan` | `scan` | Answer the cached-results prompt up front |
| `--[no-]open` | `scan` | Open the report in your editor (default: on) |
| `--[no-]format` | `remove`, `disable` | Run `dart format` on modified files (default: on) |
| `-a`, `--accept-all` | `scan`, `remove`, `disable` | Answer every prompt affirmatively; never wait for input |
| `-a`, `--accept-all` | `init` | Never wait for input; leave unflagged answers unset |
| `--all` | `remove`, `disable` | Act on everything, ignoring ticks |
| `--force` | `remove`, `disable` | Allow a dirty tree, and offer a rescan first |
| `--undo` | `disable` | Uncomment previously disabled fields |
| `--remove` | `disable` | Delete previously disabled fields for good |
| `-y`, `--yes` | `uninstall` | Do not ask for confirmation |
| `--keep-tool` | `uninstall` | Remove the editor and settings, but leave the command installed |
| `--force` | `uninstall` | Go ahead even while code is still commented out — that code becomes unrecoverable |

`gui` takes subcommands rather than flags: `install`, `uninstall`, `status`.

`--help` works on the runner and on every command; `--version` prints the
tool version and exits.

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

It installs nothing. The editor is offered by `init` and nowhere else, so
there is no prompt here for `-a` to accept — and a scan in CI never quietly
adds an extension to the build machine.

## Uninstalling

`uninstall` is the opposite of `init`: it removes the editor extension, both
config files, this project's cached reports, and then deactivates the command
itself.

```bash
amscan uninstall
```

It shows what it will remove and asks first — `-y` skips the question, and
`--keep-tool` stops short of deactivating the command. Your source code is
never touched.

**It refuses while code is still commented out.** `disable` keeps the original
source in `.dart_tool/api_model_scanner/disabled_fields.json`, not in the
commented-out file, so removing that record would leave the code unrecoverable
and looking perfectly fine. Run `disable --undo` or `disable --remove` first;
`--force` overrides the refusal and accepts the loss.

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
