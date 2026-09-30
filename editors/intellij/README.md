# amscan Report — Android Studio / IntelliJ

Shows an `api_model_scanner` report as a table of checkbox cells instead of a
Markdown list, and opens the Dart source a row names.

It is the IntelliJ counterpart of [`editors/vscode`](../vscode). Both write
the same one-character edits into the same Markdown file the CLI reads, so
neither is required and the two can be used on the same repository.

## Layout

| | |
|---|---|
| `report/` | The parser and cascade. **No IntelliJ dependency at all** — a separate Gradle module so that is enforced by the build, not by discipline. Mirrors `editors/vscode/src/report.ts`. |
| `src/` | The editor: a `FileEditorProvider`, the IDE's embedded browser, and the bridge between the two. |

The table is drawn in JCEF rather than a Swing `JTable`, because the layout
that makes a report readable — a class cell spanning its fields' rows, a field
cell spanning its parts' — is a `rowspan`, and `JTable` has no equivalent. It
also means both editors draw the table with one script, shared byte for byte
with `editors/vscode/src/webview.ts`; a test in the Dart package fails if the
two copies ever differ. It holds everything the table does: the separate,
folded table for fields read dynamically, resizable columns, and the disabled
report's code rows — see [`editors/vscode`](../vscode) for what each does.

Where the IDE has no embedded browser, the tab says so, points at the Markdown
editor beside it, and says how to turn the browser back on.

Two things differ from VS Code, both forced by the host:

- **The resize cursor is `e-resize`**, not `col-resize`. JCEF hands the page's
  cursor to Swing as one of AWT's built-in shapes, and `col-resize` does not
  survive that translation — it arrives as the plain arrow. A test in
  `:report` keeps it that way.
- **Column widths and folded tables are remembered in the embedded browser's
  storage**, which every project shares, so they carry from one project to
  the next. VS Code keeps them per editor tab.

## Building

```bash
cd editors/intellij
gradle :report:test     # the logic, in a plain JVM, in milliseconds
gradle buildPlugin      # -> build/distributions/amscan-report-intellij-<version>.zip
```

The build compiles against the Android Studio installed on this machine,
named by `amscan.ideHome` in `gradle.properties`, so no multi-gigabyte IDE SDK
has to be downloaded. Point it at any IntelliJ-platform IDE to build against
that one instead.

`test` is disabled deliberately: the platform plugin rewires it to run inside
a sandboxed IDE, and there is nothing here that needs one. The logic lives in
`:report` and tests itself without an IDE — the same property that lets
`report.ts` be tested without VS Code.

## Installing, and why a restart is needed

A JetBrains IDE reads its `plugins` directory only at startup, and there is no
supported way to ask a running one to load a plugin from a local file. So the
restart is the mechanism, not a workaround for one.

`amscan gui install` copies the plugin in and then offers to restart the IDE
for you — a graceful quit, so open projects are saved and restored. It only
offers when the IDE is running and there is a terminal to answer on; an
unattended run installs and says nothing further.

To do it by hand:

```bash
unzip -q build/distributions/amscan-report-intellij-1.1.0.zip \
  -d "$HOME/Library/Application Support/Google/AndroidStudio<version>/plugins"
```

Every extension point this plugin uses is declared `dynamic="true"`, so the
IDE is able to load it without a restart — but only through its own plugin
machinery, which a file copy does not go through.

The built plugin is committed under `plugin/` on purpose: `dart pub publish`
ships it inside the package, and `amscan gui install` copies it from there.
After changing the plugin, rebuild and refresh that copy, or the package
ships the old one:

```bash
gradle clean buildPlugin
rm -rf plugin/amscan-report-intellij
unzip -q build/distributions/amscan-report-intellij-<version>.zip -d plugin/
```

## Publishing

The Marketplace's web upload form takes **new** plugins only. Given an id it
already knows it answers "already taken" and offers to rename the plugin —
which would orphan the listing rather than update it. Every update goes
through Gradle instead:

```bash
JETBRAINS_MARKETPLACE_TOKEN='…' gradle publishPlugin
```

Make the token at <https://plugins.jetbrains.com/author/me/tokens>. It is
read from the environment, or from `intellijPlatformPublishingToken` in
`~/.gradle/gradle.properties` — never from a file in this repository. A new
version is reviewed before it goes live; the plugin's **Versions** tab, not
the public API, shows where it stands.

## Working on the plugin

```bash
gradle runIde
```

Starts a sandboxed IDE with the plugin already loaded, separate from your real
installation — the usual loop for changing the editor itself, since it needs
no install step at all.

## What is tested where

`:report` is tested in a plain JVM — parsing, the cascade, rows, JSON,
messages, and the page's markup — including the published report shapes
byte for byte as the CLI writes them. The editor itself (`src/`) only
compiles against the real platform API: whether JCEF draws the page and the
bridge carries a click back is checked by running it, in `gradle runIde` or
an installed IDE.
