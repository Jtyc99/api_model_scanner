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
| `src/` | The editor: a `FileEditorProvider` and a table bound to the document. |

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

## Installing by hand

```bash
unzip -q build/distributions/amscan-report-intellij-0.1.0.zip \
  -d "$HOME/Library/Application Support/Google/AndroidStudio<version>/plugins"
```

Then restart the IDE. There is no supported CLI for installing a plugin from
a local file, which is why this copies into the plugins directory directly.

## Not yet verified

The table has never been on screen. `:report` is tested; the editor compiles
against the real platform API, and that is the whole of what is known.
