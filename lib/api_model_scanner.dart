/// Finds API model fields that are only populated by serialization and never
/// actually used by the application, and removes them with AST-aware edits.
///
/// `scan` writes a cached report under `.dart_tool/api_model_scanner/`;
/// `remove` and `disable` consume that cache so they need not rescan.
library;

export 'src/cache/disabled_plan.dart';
export 'src/cache/disabled_store.dart';
export 'src/cache/report.dart';
export 'src/cache/unused_cache.dart';
export 'src/cli/runner.dart' show runCli;
export 'src/version.dart';
export 'src/apply_runner.dart';
export 'src/cache/selection.dart';
export 'src/lsp/dart_language_server.dart';
export 'src/model.dart';
export 'src/model_field_fixer.dart';
export 'src/scanning/dead_classes.dart';
export 'src/scanning/model_discovery.dart';
export 'src/scanning/unused_scanner.dart';
