# Flutter API Model Unused-Field Scanner

## 1. Goal

The goal is to build a **Dart CLI tool for a Flutter project** that can
scan API response models and identify model fields that are not actually
used by the application.

Example:

```dart
class HomeBanner {
  String? desktop;
  String? mobile;
  String? alt;
  dynamic page;
  bool? countdown;
  num? timestamp;
  DateTime? startDate;
  DateTime? endDate;
  num? id;
  dynamic gameUrl;
}
```

If the application only accesses:

```dart
banner.mobile
```

the scanner should identify fields such as `desktop`, `alt`, `page`,
`countdown`, `timestamp`, etc. as potentially unused.

The desired long-term workflow is:

```text
Scan project
    ↓
Find API model classes
    ↓
Find model fields
    ↓
Find semantic references to each field
    ↓
Ignore references caused only by serialization/model internals
    ↓
Report fields with no external usage
    ↓
Optionally remove them safely
    ↓
Run dart format / analysis
```

The goal is **not merely to search for matching text**. It should behave
similarly to an IDE's **Find All References / Find Usages**, so
`HomeBanner.desktop` is distinguished from an unrelated
`SomeOtherClass.desktop`.

---

## 2. What We Discussed

### Unused API response fields and performance

Receiving extra API fields can have some cost:

- Larger HTTP response size.
- More network bandwidth.
- More JSON decoding work.
- More memory if the values are retained.
- More CPU if the values are explicitly converted/parsing in
  `fromJson()`.

However, unused Dart model fields have **negligible impact on APK
size**.

For example:

```dart
startDate: json['start_date'] == null
    ? null
    : DateTime.tryParse(json['start_date'].toString()),
```

does unnecessary CPU work if `startDate` is never used.

If the API cannot be changed, it is still reasonable to parse only
fields that the application needs.

If the API can be changed, the best optimization is to make the API
return only the required fields.

### Simplifying the model

For a model used exclusively to display the mobile banner image, a
smaller model is preferable:

```dart
class HomeBanner {
  final String? mobile;

  const HomeBanner({
    this.mobile,
  });

  factory HomeBanner.fromJson(Map<String, dynamic> json) {
    return HomeBanner(
      mobile: json['mobile']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        if (mobile != null) 'mobile': mobile,
      };

  @override
  bool operator ==(Object other) =>
      identical(other, this) ||
      other is HomeBanner && other.mobile == mobile;

  @override
  int get hashCode => mobile.hashCode;
}
```

### Existing packages/tools

We discussed dead-code/unused-code tools such as:

- `dartd`
- `ciach`
- `flutter_cleanup_mcp`
- Dart's `unused_field` analyzer diagnostic
- `flutter_unused_packages`
- `coach`

These can help with general dead code, but they do **not directly solve
the specific requirement**:

> Find fields inside API models that are only populated/serialized but
> are never externally accessed anywhere in the Flutter project.

### VS Code / Android Studio approach

Android Studio's "Find Usages" and VS Code's "Find All References" are
based on semantic language analysis rather than simple text searching.

The Dart ecosystem provides the same underlying capability through the
**Dart Analysis Server / Language Server**.

The relevant LSP operation is:

```text
textDocument/references
```

This can be used to ask:

> Find references to this exact Dart element at this file/line/column.

This is a much better foundation than grep/text search.

---

## 3. Proposed Solution

The proposed tool is a standalone Dart CLI.

### High-level architecture

```text
                    Flutter project
                          │
                          ▼
                Find model .dart files
                          │
                          ▼
                  Parse Dart AST
                          │
                          ▼
                  Find class fields
                          │
                          ▼
             Start Dart Language Server
                          │
                          ▼
              Initialize LSP workspace
                          │
                          ▼
          textDocument/references per field
                          │
                          ▼
             Classify returned references
                          │
             ┌────────────┴────────────┐
             ▼                         ▼
       Internal references       External references
             │                         │
       fromJson/toJson/etc.       Actual app usage
             │                         │
             └────────────┬────────────┘
                          ▼
                  Determine field status
                          │
                          ▼
                     Report unused
                          │
                          ▼
                 Optional --fix mode
```

### AST analysis

Use the Dart `analyzer` package to parse model files and discover:

- Classes.
- Instance fields.
- Field names.
- Source locations.
- Constructors.
- `fromJson()`.
- `toJson()`.
- Other model-related methods.

The current Analyzer API uses:

```dart
declaration.namePart
```

instead of the old:

```dart
declaration.name
```

and:

```dart
declaration.body.members
```

instead of the old:

```dart
declaration.members
```

This matters because newer Analyzer versions removed the old APIs.

### Semantic reference lookup

Start:

```bash
dart language-server \
  --protocol=lsp \
  --client-id=api-model-scanner \
  --client-version=1.0.0
```

Then communicate using LSP JSON-RPC.

For each field, issue:

```text
textDocument/references
```

at the field declaration's source position.

Conceptually:

```text
HomeBanner.desktop
        │
        ▼
LSP textDocument/references
        │
        ▼
All semantic references
```

### Why semantic references are important

Text search is insufficient.

For example:

```dart
HomeBanner.desktop
```

should not be confused with:

```dart
OtherModel.desktop
```

Semantic reference lookup can distinguish the actual Dart element.

---

## 4. Possible Issues

### 4.1 LSP framing

LSP messages are **not line-delimited JSON**.

They use headers such as:

```text
Content-Length: 1234\r\n
Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n
\r\n
{JSON body}
```

Therefore this approach is incorrect:

```dart
_process.stdout
    .transform(utf8.decoder)
    .transform(const LineSplitter())
```

The scanner must read raw bytes and parse `Content-Length`.

The previous implementation had this bug, which caused:

```text
TimeoutException: LSP request timed out: initialize
```

because the initialization response was not being parsed correctly.

### 4.2 `Content-Length` is bytes, not Dart characters

The LSP `Content-Length` header is measured in UTF-8 bytes.

Do not calculate the body length using Dart string length.

Correct:

```dart
final body = utf8.encode(jsonEncode(message));
final contentLength = body.length;
```

### 4.3 Analyzer API compatibility

The Dart `analyzer` package changes APIs between versions.

The previous implementation used outdated APIs:

```dart
declaration.name
declaration.members
```

For current Analyzer versions, use:

```dart
declaration.namePart.name.lexeme
```

and:

```dart
declaration.body.members
```

The scanner should pin an Analyzer version compatible with the Dart SDK
used to run the CLI.

### 4.4 Dart SDK vs Flutter SDK mismatch

The scanner must be careful about which `dart` executable it starts.

Check:

```bash
which dart
dart --version
flutter --version
```

It is possible to have multiple Flutter/Dart installations where:

```bash
dart
```

and:

```bash
flutter
```

use different SDK versions.

This can cause Analyzer and Language Server incompatibilities.

### 4.5 Language server initialization

The LSP sequence should be:

```text
Start server
    ↓
initialize
    ↓
receive InitializeResult
    ↓
initialized
    ↓
workspace analysis
    ↓
reference requests
```

The server may appear to hang when manually started because it is
waiting for the client to send `initialize`.

### 4.6 Workspace/document synchronization

A standalone CLI is not identical to VS Code.

VS Code keeps documents synchronized with the language server.

A robust CLI should consider sending:

```text
textDocument/didOpen
```

for model files before requesting references, or otherwise ensure that
the analyzer has loaded/analyzed the workspace.

### 4.7 Serialization references must be ignored

A field can appear to have references even when the application never
uses it.

Example:

```dart
desktop: json['desktop']?.toString(),
```

and:

```dart
if (desktop != null) 'desktop': desktop,
```

These are internal serialization references.

The scanner should distinguish:

```text
INTERNAL
HomeBanner.fromJson()
HomeBanner.toJson()
HomeBanner constructor
HomeBanner == / hashCode
```

from:

```text
EXTERNAL
HomePage
BannerWidget
BannerController
etc.
```

Only external references should determine whether a field is actually
used.

### 4.8 Reflection / dynamic access

Dynamic code can make static reference analysis incomplete.

Examples:

```dart
object['mobile']
```

or reflection-like serialization frameworks.

The scanner should therefore report:

```text
Potentially unused
```

rather than claiming absolute certainty.

### 4.9 Generated code

If models use generated serializers/code such as:

```text
*.g.dart
```

the scanner needs explicit rules for generated references.

Otherwise generated code can make an apparently unused field look used.

### 4.10 Shared models

A field might currently have zero usages but still be intentionally part
of a reusable API model.

Therefore automatic deletion should not be enabled by default.

---

## 5. Improvements / Bug Fixes

### 5.1 Fix the LSP transport

Replace the original line-based stdout parser with byte-level parsing.

The scanner should:

1. Read raw stdout bytes.
2. Find `\r\n\r\n`.
3. Parse `Content-Length`.
4. Wait until exactly that many bytes are available.
5. Decode the body as UTF-8.
6. Parse JSON.
7. Match the JSON-RPC response ID to the pending request.

This fixes the `initialize` timeout caused by the previous parser.

### 5.2 Add proper initialization

Use:

```bash
dart language-server \
  --protocol=lsp \
  --client-id=api-model-scanner \
  --client-version=1.0.0
```

Then send `initialize` and wait for the response before sending
`initialized`.

### 5.3 Wait for workspace analysis

The scanner should wait until the language server has had enough time to
analyze the project before requesting references.

Ideally, listen for analysis/status notifications instead of using an
arbitrary delay.

### 5.4 Open/synchronize model files

Send `textDocument/didOpen` for files being scanned where necessary.

This makes standalone LSP usage closer to what VS Code does.

### 5.5 Identify JSON field mappings

The scanner should inspect `fromJson()` and build mappings such as:

```text
Dart field       JSON field
--------------------------------
desktop          desktop
mobile           mobile
alt              alt
page             page
countdown        countdown
timestamp        timestamp
startDate        start_date
endDate          end_date
id               id
gameUrl          game_url
```

Then the output can be more useful:

```text
HomeBanner.desktop
JSON field: desktop
External references: 0
Status: POTENTIALLY UNUSED
```

### 5.6 Detect model serialization internals

The scanner should explicitly recognize and exclude references
originating from:

- `fromJson`
- `toJson`
- constructors
- `==`
- `hashCode`
- generated serialization
- the model's own class body

### 5.7 Produce useful reports

Recommended default output:

```text
API Model Field Scanner

HomeBanner
────────────────────────────────────
✓ mobile
  External references: 12

✗ desktop
  External references: 0

✗ alt
  External references: 0

✗ startDate
  External references: 0
```

Potentially include source locations:

```text
desktop
  home_banner.dart:12
```

### 5.8 Add JSON output

Support:

```bash
dart run tool/api_model_scanner.dart --json
```

This allows CI scripts or other tools to consume the results.

Example:

```json
{
  "HomeBanner": {
    "mobile": {
      "references": 12,
      "unused": false
    },
    "desktop": {
      "references": 0,
      "unused": true
    }
  }
}
```

### 5.9 Add dry-run mode

Before changing files:

```bash
dart run tool/api_model_scanner.dart --dry-run
```

should show exactly what would be removed without modifying anything.

### 5.10 Add `--fix`

After the scanner is reliable:

```bash
dart run tool/api_model_scanner.dart --fix
```

could remove an unused field from:

- Field declaration.
- Constructor.
- `fromJson`.
- `toJson`.
- `==`.
- `hashCode`.

Then run:

```bash
dart format .
```

and optionally:

```bash
dart analyze
```

### 5.11 Use AST rewriting rather than regex

The fixer should **not** use regex/string replacement.

It should use AST-aware source editing so that formatting and unrelated
code are not accidentally damaged.

### 5.12 Git safety

Before `--fix`, the tool should ideally:

1. Require a clean Git working tree, or warn if it is dirty.
2. Print all fields that will be removed.
3. Support `--dry-run`.
4. Make only targeted source edits.
5. Run `dart format`.
6. Optionally run `dart analyze`.

### 5.13 Recommended commands

The eventual CLI could expose:

```bash
# Scan default model directory
dart run tool/api_model_scanner.dart

# Scan a custom model directory
dart run tool/api_model_scanner.dart --models lib/data/models

# Machine-readable output
dart run tool/api_model_scanner.dart --json

# Show what would be changed
dart run tool/api_model_scanner.dart --dry-run

# Actually remove fields
dart run tool/api_model_scanner.dart --fix
```

---

## Recommended Final Architecture

The final implementation should be split into these components:

```text
tool/api_model_scanner/
├── api_model_scanner.dart
├── analyzer/
│   ├── model_discovery.dart
│   ├── field_discovery.dart
│   └── json_mapping.dart
├── lsp/
│   ├── dart_language_server.dart
│   └── json_rpc_transport.dart
├── analysis/
│   ├── reference_analyzer.dart
│   └── reference_filter.dart
├── reporting/
│   └── report.dart
└── fixing/
    └── model_fixer.dart
```

The most important design principle is:

> **Use Dart's semantic analysis/LSP to determine whether a model field
> is externally referenced, and use AST-aware source modification only
> after that determination is made.**

This provides a much more accurate solution than generic dead-code
detection or text-based searching, while directly targeting the original
requirement: finding API model fields that are only present because the
API returns them but are never actually used by the Flutter application.
