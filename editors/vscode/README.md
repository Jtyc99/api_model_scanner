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
code --install-extension amscan-report-0.1.0.vsix
```

`Open as text` in the toolbar reopens the raw Markdown, and VS Code's
**Reopen Editor With…** switches back either way.

## Not built yet

The JetBrains half. Android Studio / IntelliJ would need a separate
`FileEditorProvider` with a Swing or JCEF table — the same idea, a second
implementation. Until then, the Markdown report's relative links keep it
usable there by hand.
