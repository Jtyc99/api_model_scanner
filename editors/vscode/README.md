# API Model Scanner report — VS Code editor

Opens `unused_fields.md` and `disabled_fields.md` as a **real table with
checkbox cells**, which Markdown cannot do: GFM only makes checkboxes
interactive inside list items, never inside table cells, in every mainstream
preview.

## What it gives you over the Markdown

| | Markdown preview | This editor |
|---|---|---|
| Layout | nested lists | a real table |
| Toggling | type `x` (VS Code's preview does not toggle) | click the cell |
| Editing | the whole file is editable | only the checkboxes |
| Jump to source | `vscode://` link per row | click the row's line |
| Filter | editor find | a filter box over field names |
| Columns | fixed by the text | drag an edge to resize, double-click to fit |

Text too long for its column ends in an ellipsis and shows in full on hover.
Columns start fitted to their content; **Fit columns** undoes any dragging.
Widths, like which tables are folded, are remembered.

## Fields read dynamically

A field the CLI found read through a `dynamic` receiver — which no reference
search can follow, so removing it compiles and then throws — gets a table of
its own, **on top**, with a **Read At** column that opens each read. It starts
folded, since nothing in it is taken without a tick of its own: the bar stays
in view with a count, a line saying why those rows are there, and **Show**.
The table everything acts on starts open. While filtering, any table with a
match opens.

Select All and class boxes never reach that table. Only a tick on the field
itself, or on one of its parts, selects it — and the CLI names each read
before it acts.

In `disabled_fields.md` the same split holds, and each disabled field lists
the code it had commented out. The report words each section's heading, so
the disabled one does not call its table "Unused".

## How it stays safe

The Markdown file remains the single source of truth. Every toggle is a
**one-character `WorkspaceEdit`** on the underlying document — the character
between the brackets and nothing else — so the row's text, links and padding
are untouched, and the Dart CLI keeps parsing the same file it always did.

That has two consequences worth knowing:

- Nothing is lost if the extension is not installed. The report is still a
  Markdown file you can tick by hand.
- Undo is ordinary editor undo, and a "Tick all" is a single undo step.

The parser in `src/report.ts` deliberately mirrors
`lib/src/cache/selection.dart`. Both derive identity from the document's
structure — a `##` heading names the class, an unindented task item names a
field, indented task items are its parts in order — so neither can rely on
anything invisible in the file.

The dynamic-read section is written in shapes of its own — `###` headings,
`*` bullets, `Declared in` — which no editor released before it recognises.
That is deliberate: an older editor cannot take those rows for ordinary ones
and tick them from Select All. To it, the section is simply not there.

The table itself is drawn by a script shared, byte for byte, with the
Android Studio plugin; a test in the Dart package fails if the two copies
ever differ.

## Developing

```bash
npm install
npm run compile
npm test        # parser tests, no editor host needed
```

Press <kbd>F5</kbd> in VS Code to launch an Extension Development Host, then
open a report under `.dart_tool/api_model_scanner/`.

To install it locally:

```bash
npm run package
code --install-extension amscan-report-1.1.0.vsix
```

The built `.vsix` is committed on purpose: `dart pub publish` ships it inside
the package, and the CLI installs it from there when the Marketplace cannot be
reached — or for VS Code forks, which use OpenVSX instead. Rebuild it
whenever `src/` changes, or the package ships the old one.

`Open as text` in the toolbar reopens the raw Markdown, and VS Code's
**Reopen Editor With…** switches back either way.

## Android Studio

The same table exists for Android Studio and every other IntelliJ-platform
IDE — see [`editors/intellij`](../intellij).
